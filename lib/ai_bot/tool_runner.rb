# frozen_string_literal: true

module DiscourseAi
  module AiBot
    class ToolRunner
      attr_reader :tool, :parameters, :llm
      attr_accessor :running_attached_function, :timeout, :custom_raw

      TooManyRequestsError = Class.new(StandardError)

      DEFAULT_TIMEOUT = 2000
      MAX_MEMORY = 10_000_000
      MARSHAL_STACK_DEPTH = 20
      MAX_HTTP_REQUESTS = 20

      def initialize(parameters:, llm:, bot_user:, context: {}, tool:, timeout: nil)
        @parameters = parameters
        @llm = llm
        @bot_user = bot_user
        @context = context
        @tool = tool
        @timeout = timeout || DEFAULT_TIMEOUT
        @running_attached_function = false

        @http_requests_made = 0
      end

      def mini_racer_context
        @mini_racer_context ||=
          begin
            ctx =
              MiniRacer::Context.new(
                max_memory: MAX_MEMORY,
                marshal_stack_depth: MARSHAL_STACK_DEPTH,
              )
            attach_truncate(ctx)
            attach_http(ctx)
            attach_index(ctx)
            attach_upload(ctx)
            attach_chain(ctx)
            attach_discourse(ctx)
            ctx.eval(framework_script)
            ctx
          end
      end

      def framework_script
        http_methods = %i[get post put patch delete].map { |method| <<~JS }.join("\n")
          #{method}: function(url, options) {
            return _http_#{method}(url, options);
          },
          JS
        <<~JS
        const http = {
          #{http_methods}
        };

        const llm = {
          truncate: _llm_truncate,
          generate: _llm_generate,
        };

        const index = {
          search: _index_search,
        }

        const upload = {
          create: _upload_create,
        }

        const chain = {
          setCustomRaw: _chain_set_custom_raw,
        };

        const discourse = {
          search: function(params) {
            return _discourse_search(params);
          },
          getPost: _discourse_get_post,
          getUser: _discourse_get_user,
          getPersona: function(name) {
            return {
              respondTo: function(params) {
                result = _discourse_respond_to_persona(name, params);
                if (result.error) {
                  throw new Error(result.error);
                }
                return result;
              },
            };
          },
        };

        const context = #{JSON.generate(@context)};

        function details() { return ""; };
      JS
      end

      def details
        eval_with_timeout("details()")
      end

      def eval_with_timeout(script, timeout: nil)
        timeout ||= @timeout
        mutex = Mutex.new
        done = false
        elapsed = 0

        t =
          Thread.new do
            begin
              while !done
                # this is not accurate. but reasonable enough for a timeout
                sleep(0.001)
                elapsed += 1 if !self.running_attached_function
                if elapsed > timeout
                  mutex.synchronize { mini_racer_context.stop unless done }
                  break
                end
              end
            rescue => e
              STDERR.puts e
              STDERR.puts "FAILED TO TERMINATE DUE TO TIMEOUT"
            end
          end

        rval = mini_racer_context.eval(script)

        mutex.synchronize { done = true }

        # ensure we do not leak a thread in state
        t.join
        t = nil

        rval
      ensure
        # exceptions need to be handled
        t&.join
      end

      def invoke
        mini_racer_context.eval(tool.script)
        eval_with_timeout("invoke(#{JSON.generate(parameters)})")
      rescue MiniRacer::ScriptTerminatedError
        { error: "Script terminated due to timeout" }
      end

      private

      MAX_FRAGMENTS = 200

      def rag_search(query, filenames: nil, limit: 10)
        limit = limit.to_i
        return [] if limit < 1
        limit = [MAX_FRAGMENTS, limit].min

        upload_refs =
          UploadReference.where(target_id: tool.id, target_type: "AiTool").pluck(:upload_id)

        if filenames
          upload_refs = Upload.where(id: upload_refs).where(original_filename: filenames).pluck(:id)
        end

        return [] if upload_refs.empty?

        query_vector = DiscourseAi::Embeddings::Vector.instance.vector_from(query)
        fragment_ids =
          DiscourseAi::Embeddings::Schema
            .for(RagDocumentFragment)
            .asymmetric_similarity_search(query_vector, limit: limit, offset: 0) do |builder|
              builder.join(<<~SQL, target_id: tool.id, target_type: "AiTool")
                rag_document_fragments ON
                  rag_document_fragments.id = rag_document_fragment_id AND
                  rag_document_fragments.target_id = :target_id AND
                  rag_document_fragments.target_type = :target_type
              SQL
            end
            .map(&:rag_document_fragment_id)

        fragments =
          RagDocumentFragment.where(id: fragment_ids, upload_id: upload_refs).pluck(
            :id,
            :fragment,
            :metadata,
          )

        mapped = {}
        fragments.each do |id, fragment, metadata|
          mapped[id] = { fragment: fragment, metadata: metadata }
        end

        fragment_ids.take(limit).map { |fragment_id| mapped[fragment_id] }
      end

      def attach_truncate(mini_racer_context)
        mini_racer_context.attach(
          "_llm_truncate",
          ->(text, length) { @llm.tokenizer.truncate(text, length) },
        )

        mini_racer_context.attach(
          "_llm_generate",
          ->(prompt) do
            in_attached_function do
              @llm.generate(
                convert_js_prompt_to_ruby(prompt),
                user: llm_user,
                feature_name: "custom_tool_#{tool.name}",
              )
            end
          end,
        )
      end

      def convert_js_prompt_to_ruby(prompt)
        if prompt.is_a?(String)
          prompt
        elsif prompt.is_a?(Hash)
          messages = prompt["messages"]
          if messages.blank? || !messages.is_a?(Array)
            raise Discourse::InvalidParameters.new("Prompt must have messages")
          end
          messages.each(&:symbolize_keys!)
          messages.each { |message| message[:type] = message[:type].to_sym }
          DiscourseAi::Completions::Prompt.new(messages: prompt["messages"])
        else
          raise Discourse::InvalidParameters.new("Prompt must be a string or a hash")
        end
      end

      def llm_user
        @llm_user ||=
          begin
            @context[:llm_user] || post&.user || @bot_user
          end
      end

      def post
        return @post if defined?(@post)
        post_id = @context[:post_id]
        @post = post_id && Post.find_by(id: post_id)
      end

      def attach_index(mini_racer_context)
        mini_racer_context.attach(
          "_index_search",
          ->(*params) do
            in_attached_function do
              query, options = params
              self.running_attached_function = true
              options ||= {}
              options = options.symbolize_keys
              self.rag_search(query, **options)
            end
          end,
        )
      end

      def attach_chain(mini_racer_context)
        mini_racer_context.attach("_chain_set_custom_raw", ->(raw) { self.custom_raw = raw })
      end

      def attach_discourse(mini_racer_context)
        mini_racer_context.attach(
          "_discourse_get_post",
          ->(post_id) do
            in_attached_function do
              post = Post.find_by(id: post_id)
              return nil if post.nil?
              guardian = Guardian.new(Discourse.system_user)
              recursive_as_json(PostSerializer.new(post, scope: guardian, root: false))
            end
          end,
        )

        mini_racer_context.attach(
          "_discourse_get_user",
          ->(user_id_or_username) do
            in_attached_function do
              user = nil

              if user_id_or_username.is_a?(Integer) ||
                   user_id_or_username.to_i.to_s == user_id_or_username
                user = User.find_by(id: user_id_or_username.to_i)
              else
                user = User.find_by(username: user_id_or_username)
              end

              return nil if user.nil?

              guardian = Guardian.new(Discourse.system_user)
              recursive_as_json(UserSerializer.new(user, scope: guardian, root: false))
            end
          end,
        )

        mini_racer_context.attach(
          "_discourse_respond_to_persona",
          ->(persona_name, params) do
            in_attached_function do
              # if we have 1000s of personas this can be slow ... we may need to optimize
              persona_class = AiPersona.all_personas.find { |persona| persona.name == persona_name }
              return { error: "Persona not found" } if persona_class.nil?

              persona = persona_class.new
              bot = DiscourseAi::AiBot::Bot.as(@bot_user || persona.user, persona: persona)
              playground = DiscourseAi::AiBot::Playground.new(bot)

              if @context[:post_id]
                post = Post.find_by(id: @context[:post_id])
                return { error: "Post not found" } if post.nil?

                reply_post =
                  playground.reply_to(
                    post,
                    custom_instructions: params["instructions"],
                    whisper: params["whisper"],
                  )

                if reply_post
                  return(
                    { success: true, post_id: reply_post.id, post_number: reply_post.post_number }
                  )
                else
                  return { error: "Failed to create reply" }
                end
              elsif @context[:message_id] && @context[:channel_id]
                message = Chat::Message.find_by(id: @context[:message_id])
                channel = Chat::Channel.find_by(id: @context[:channel_id])
                return { error: "Message or channel not found" } if message.nil? || channel.nil?

                reply =
                  playground.reply_to_chat_message(message, channel, @context[:context_post_ids])

                if reply
                  return { success: true, message_id: reply.id }
                else
                  return { error: "Failed to create chat reply" }
                end
              else
                return { error: "No valid context for response" }
              end
            end
          end,
        )

        mini_racer_context.attach(
          "_discourse_search",
          ->(params) do
            in_attached_function do
              search_params = params.symbolize_keys
              if search_params.delete(:with_private)
                search_params[:current_user] = Discourse.system_user
              end
              search_params[:result_style] = :detailed
              results = DiscourseAi::Utils::Search.perform_search(**search_params)
              recursive_as_json(results)
            end
          end,
        )
      end

      def attach_upload(mini_racer_context)
        mini_racer_context.attach(
          "_upload_create",
          ->(filename, base_64_content) do
            begin
              in_attached_function do
                # protect against misuse
                filename = File.basename(filename)

                Tempfile.create(filename) do |file|
                  file.binmode
                  file.write(Base64.decode64(base_64_content))
                  file.rewind

                  upload =
                    UploadCreator.new(
                      file,
                      filename,
                      for_private_message: @context[:private_message],
                    ).create_for(@bot_user.id)

                  { id: upload.id, short_url: upload.short_url, url: upload.url }
                end
              end
            end
          end,
        )
      end

      def attach_http(mini_racer_context)
        mini_racer_context.attach(
          "_http_get",
          ->(url, options) do
            begin
              @http_requests_made += 1
              if @http_requests_made > MAX_HTTP_REQUESTS
                raise TooManyRequestsError.new("Tool made too many HTTP requests")
              end

              in_attached_function do
                headers = (options && options["headers"]) || {}

                result = {}
                DiscourseAi::AiBot::Tools::Tool.send_http_request(
                  url,
                  headers: headers,
                ) do |response|
                  result[:body] = response.body
                  result[:status] = response.code.to_i
                end

                result
              end
            end
          end,
        )

        %i[post put patch delete].each do |method|
          mini_racer_context.attach(
            "_http_#{method}",
            ->(url, options) do
              begin
                @http_requests_made += 1
                if @http_requests_made > MAX_HTTP_REQUESTS
                  raise TooManyRequestsError.new("Tool made too many HTTP requests")
                end

                in_attached_function do
                  headers = (options && options["headers"]) || {}
                  body = options && options["body"]

                  result = {}
                  DiscourseAi::AiBot::Tools::Tool.send_http_request(
                    url,
                    method: method,
                    headers: headers,
                    body: body,
                  ) do |response|
                    result[:body] = response.body
                    result[:status] = response.code.to_i
                  end

                  result
                rescue => e
                  if Rails.env.development?
                    p url
                    p options
                    p e
                    puts e.backtrace
                  end
                  raise e
                end
              end
            end,
          )
        end
      end

      def in_attached_function
        self.running_attached_function = true
        yield
      ensure
        self.running_attached_function = false
      end

      def recursive_as_json(obj)
        case obj
        when Array
          obj.map { |item| recursive_as_json(item) }
        when Hash
          obj.transform_values { |value| recursive_as_json(value) }
        when ActiveModel::Serializer, ActiveModel::ArraySerializer
          recursive_as_json(obj.as_json)
        when ActiveRecord::Base
          recursive_as_json(obj.as_json)
        else
          # Handle objects that respond to as_json but aren't handled above
          if obj.respond_to?(:as_json)
            result = obj.as_json
            if result.equal?(obj)
              # If as_json returned the same object, return it to avoid infinite recursion
              result
            else
              recursive_as_json(result)
            end
          else
            # Primitive values like strings, numbers, booleans, nil
            obj
          end
        end
      end
    end
  end
end
