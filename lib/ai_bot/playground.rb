# frozen_string_literal: true

module DiscourseAi
  module AiBot
    class Playground
      attr_reader :bot

      # An abstraction to manage the bot and topic interactions.
      # The bot will take care of completions while this class updates the topic title
      # and stream replies.

      def self.find_chat_persona(message, channel, user)
        if channel.direct_message_channel?
          AiPersona
            .allowed_modalities(allow_chat_direct_messages: true)
            .find do |p|
              p[:user_id].in?(channel.allowed_user_ids) && (user.group_ids & p[:allowed_group_ids])
            end
        else
          # let's defer on the parse if there is no @ in the message
          if message.message.include?("@")
            mentions = message.parsed_mentions.parsed_direct_mentions
            if mentions.present?
              AiPersona
                .allowed_modalities(allow_chat_channel_mentions: true)
                .find { |p| p[:username].in?(mentions) && (user.group_ids & p[:allowed_group_ids]) }
            end
          end
        end
      end

      def self.schedule_chat_reply(message, channel, user, context)
        return if !SiteSetting.ai_bot_enabled

        all_chat =
          AiPersona.allowed_modalities(
            allow_chat_channel_mentions: true,
            allow_chat_direct_messages: true,
          )
        return if all_chat.blank?
        return if all_chat.any? { |m| m[:user_id] == user.id }

        persona = find_chat_persona(message, channel, user)
        return if !persona

        post_ids = nil
        post_ids = context.dig(:context, :post_ids) if context.is_a?(Hash)

        ::Jobs.enqueue(
          :create_ai_chat_reply,
          channel_id: channel.id,
          message_id: message.id,
          persona_id: persona[:id],
          context_post_ids: post_ids,
        )
      end

      def self.is_bot_user_id?(user_id)
        # this will catch everything and avoid any feedback loops
        # we could get feedback loops between say discobot and ai-bot or third party plugins
        # and bots
        user_id.to_i <= 0
      end

      def self.schedule_reply(post)
        return if is_bot_user_id?(post.user_id)
        mentionables = nil

        if post.topic.private_message?
          mentionables =
            AiPersona.allowed_modalities(user: post.user, allow_personal_messages: true)
        else
          mentionables = AiPersona.allowed_modalities(user: post.user, allow_topic_mentions: true)
        end

        bot_user = nil
        mentioned = nil

        all_llm_user_ids = LlmModel.joins(:user).pluck("users.id")

        if post.topic.private_message?
          # this is an edge case, you started a PM with a different bot
          bot_user = post.topic.topic_allowed_users.where(user_id: all_llm_user_ids).first&.user
          bot_user ||=
            post
              .topic
              .topic_allowed_users
              .where(user_id: mentionables.map { |m| m[:user_id] })
              .first
              &.user
        end

        if mentionables.present?
          mentions = post.mentions.map(&:downcase)

          # in case we are replying to a post by a bot
          if post.reply_to_post_number && post.reply_to_post&.user
            mentions << post.reply_to_post.user.username_lower
          end

          mentioned = mentionables.find { |mentionable| mentions.include?(mentionable[:username]) }

          # direct PM to mentionable
          if !mentioned && bot_user
            mentioned = mentionables.find { |mentionable| bot_user.id == mentionable[:user_id] }
          end

          # public topic so we need to use the persona user
          bot_user ||= User.find_by(id: mentioned[:user_id]) if mentioned
        end

        if bot_user && post.reply_to_post_number && !post.reply_to_post.user&.bot?
          # replying to a non-bot user
          return
        end

        if bot_user
          persona_id = mentioned&.dig(:id) || post.topic.custom_fields["ai_persona_id"]
          persona = nil

          if persona_id
            persona =
              DiscourseAi::AiBot::Personas::Persona.find_by(user: post.user, id: persona_id.to_i)
          end

          if !persona && persona_name = post.topic.custom_fields["ai_persona"]
            persona =
              DiscourseAi::AiBot::Personas::Persona.find_by(user: post.user, name: persona_name)
          end

          persona ||= DiscourseAi::AiBot::Personas::General

          bot_user = User.find(persona.user_id) if persona && persona.force_default_llm

          bot = DiscourseAi::AiBot::Bot.as(bot_user, persona: persona.new)
          new(bot).update_playground_with(post)
        end
      end

      def initialize(bot)
        @bot = bot
      end

      def update_playground_with(post)
        schedule_bot_reply(post) if can_attach?(post)
      end

      def conversation_context(post)
        # Pay attention to the `post_number <= ?` here.
        # We want to inject the last post as context because they are translated differently.

        # also setting default to 40, allowing huge contexts costs lots of tokens
        max_posts = 40
        if bot.persona.class.respond_to?(:max_context_posts)
          max_posts = bot.persona.class.max_context_posts || 40
        end

        post_types = [Post.types[:regular]]
        post_types << Post.types[:whisper] if post.post_type == Post.types[:whisper]

        context =
          post
            .topic
            .posts
            .joins(:user)
            .joins("LEFT JOIN post_custom_prompts ON post_custom_prompts.post_id = posts.id")
            .where("post_number <= ?", post.post_number)
            .order("post_number desc")
            .where("post_type in (?)", post_types)
            .limit(max_posts)
            .pluck(
              "posts.raw",
              "users.username",
              "post_custom_prompts.custom_prompt",
              "(
                  SELECT array_agg(ref.upload_id)
                  FROM upload_references ref
                  WHERE ref.target_type = 'Post' AND ref.target_id = posts.id
               ) as upload_ids",
            )

        builder = DiscourseAi::Completions::PromptMessagesBuilder.new

        context.reverse_each do |raw, username, custom_prompt, upload_ids|
          custom_prompt_translation =
            Proc.new do |message|
              # We can't keep backwards-compatibility for stored functions.
              # Tool syntax requires a tool_call_id which we don't have.
              if message[2] != "function"
                custom_context = {
                  content: message[0],
                  type: message[2].present? ? message[2].to_sym : :model,
                }

                custom_context[:id] = message[1] if custom_context[:type] != :model
                custom_context[:name] = message[3] if message[3]

                builder.push(**custom_context)
              end
            end

          if custom_prompt.present?
            custom_prompt.each(&custom_prompt_translation)
          else
            context = {
              content: raw,
              type: (available_bot_usernames.include?(username) ? :model : :user),
            }

            context[:id] = username if context[:type] == :user

            if upload_ids.present? && context[:type] == :user && bot.persona.class.vision_enabled
              context[:upload_ids] = upload_ids.compact
            end

            builder.push(**context)
          end
        end

        builder.to_a
      end

      def title_playground(post)
        context = conversation_context(post)

        bot
          .get_updated_title(context, post)
          .tap do |new_title|
            PostRevisor.new(post.topic.first_post, post.topic).revise!(
              bot.bot_user,
              title: new_title.sub(/\A"/, "").sub(/"\Z/, ""),
            )
          end

        allowed_users = post.topic.topic_allowed_users.pluck(:user_id)
        MessageBus.publish(
          "/discourse-ai/ai-bot/topic/#{post.topic.id}",
          { title: post.topic.title },
          user_ids: allowed_users,
        )
      end

      def chat_context(message, channel, persona_user, context_post_ids)
        has_vision = bot.persona.class.vision_enabled
        include_thread_titles = !channel.direct_message_channel? && !message.thread_id

        current_id = message.id
        if !channel.direct_message_channel?
          # we are interacting via mentions ... strip mention
          instruction_message = message.message.gsub(/@#{bot.bot_user.username}/i, "").strip
        end

        messages = nil

        max_messages = 40
        if bot.persona.class.respond_to?(:max_context_posts)
          max_messages = bot.persona.class.max_context_posts || 40
        end

        if !message.thread_id && channel.direct_message_channel?
          messages = [message]
        elsif !channel.direct_message_channel? && !message.thread_id
          messages =
            Chat::Message
              .joins("left join chat_threads on chat_threads.id = chat_messages.thread_id")
              .where(chat_channel_id: channel.id)
              .where(
                "chat_messages.thread_id IS NULL OR chat_threads.original_message_id = chat_messages.id",
              )
              .order(id: :desc)
              .limit(max_messages)
              .to_a
              .reverse
        end

        messages ||=
          ChatSDK::Thread.last_messages(
            thread_id: message.thread_id,
            guardian: Discourse.system_user.guardian,
            page_size: max_messages,
          )

        builder = DiscourseAi::Completions::PromptMessagesBuilder.new

        guardian = Guardian.new(message.user)
        if context_post_ids
          builder.set_chat_context_posts(context_post_ids, guardian, include_uploads: has_vision)
        end

        messages.each do |m|
          # restore stripped message
          m.message = instruction_message if m.id == current_id && instruction_message

          if available_bot_user_ids.include?(m.user_id)
            builder.push(type: :model, content: m.message)
          else
            upload_ids = nil
            upload_ids = m.uploads.map(&:id) if has_vision && m.uploads.present?
            mapped_message = m.message

            thread_title = nil
            thread_title = m.thread&.title if include_thread_titles && m.thread_id
            mapped_message = "(#{thread_title})\n#{m.message}" if thread_title

            builder.push(
              type: :user,
              content: mapped_message,
              name: m.user.username,
              upload_ids: upload_ids,
            )
          end
        end

        builder.to_a(
          limit: max_messages,
          style: channel.direct_message_channel? ? :chat_with_context : :chat,
        )
      end

      def reply_to_chat_message(message, channel, context_post_ids)
        persona_user = User.find(bot.persona.class.user_id)

        participants = channel.user_chat_channel_memberships.map { |m| m.user.username }

        context_post_ids = nil if !channel.direct_message_channel?

        context =
          get_context(
            participants: participants.join(", "),
            conversation_context: chat_context(message, channel, persona_user, context_post_ids),
            user: message.user,
            skip_tool_details: true,
          )

        reply = nil
        guardian = Guardian.new(persona_user)

        force_thread = message.thread_id.nil? && channel.direct_message_channel?
        in_reply_to_id = channel.direct_message_channel? ? message.id : nil

        new_prompts =
          bot.reply(context) do |partial, cancel, placeholder|
            if !reply
              # just eat all leading spaces we can not create the message
              next if partial.blank?
              reply =
                ChatSDK::Message.create(
                  raw: partial,
                  thread_id: message.thread_id,
                  channel_id: channel.id,
                  guardian: guardian,
                  in_reply_to_id: in_reply_to_id,
                  force_thread: force_thread,
                  enforce_membership: !channel.direct_message_channel?,
                )
              ChatSDK::Message.start_stream(message_id: reply.id, guardian: guardian)
            else
              streaming =
                ChatSDK::Message.stream(message_id: reply.id, raw: partial, guardian: guardian)

              if !streaming
                cancel&.call
                break
              end
            end
          end

        if new_prompts.length > 1 && reply.id
          ChatMessageCustomPrompt.create!(message_id: reply.id, custom_prompt: new_prompts)
        end

        ChatSDK::Message.stop_stream(message_id: reply.id, guardian: guardian) if reply

        reply
      end

      def get_context(participants:, conversation_context:, user:, skip_tool_details: nil)
        result = {
          site_url: Discourse.base_url,
          site_title: SiteSetting.title,
          site_description: SiteSetting.site_description,
          time: Time.zone.now,
          participants: participants,
          conversation_context: conversation_context,
          user: user,
        }

        result[:skip_tool_details] = true if skip_tool_details

        result
      end

      def reply_to(post)
        reply = +""
        start = Time.now

        post_type =
          post.post_type == Post.types[:whisper] ? Post.types[:whisper] : Post.types[:regular]

        context =
          get_context(
            participants: post.topic.allowed_users.map(&:username).join(", "),
            conversation_context: conversation_context(post),
            user: post.user,
          )
        context[:post_id] = post.id
        context[:topic_id] = post.topic_id
        context[:private_message] = post.topic.private_message?

        reply_user = bot.bot_user
        if bot.persona.class.respond_to?(:user_id)
          reply_user = User.find_by(id: bot.persona.class.user_id) || reply_user
        end

        stream_reply = post.topic.private_message?

        # we need to ensure persona user is allowed to reply to the pm
        if post.topic.private_message?
          if !post.topic.topic_allowed_users.exists?(user_id: reply_user.id)
            post.topic.topic_allowed_users.create!(user_id: reply_user.id)
          end
        end

        if stream_reply
          reply_post =
            PostCreator.create!(
              reply_user,
              topic_id: post.topic_id,
              raw: "",
              skip_validations: true,
              skip_jobs: true,
              post_type: post_type,
            )

          publish_update(reply_post, { raw: reply_post.cooked })

          redis_stream_key = "gpt_cancel:#{reply_post.id}"
          Discourse.redis.setex(redis_stream_key, 60, 1)
        end

        context[:skip_tool_details] ||= !bot.persona.class.tool_details

        new_custom_prompts =
          bot.reply(context) do |partial, cancel, placeholder|
            reply << partial
            raw = reply.dup
            raw << "\n\n" << placeholder if placeholder.present? && !context[:skip_tool_details]

            if stream_reply && !Discourse.redis.get(redis_stream_key)
              cancel&.call
              reply_post.update!(raw: reply, cooked: PrettyText.cook(reply))
            end

            if stream_reply
              # Minor hack to skip the delay during tests.
              if placeholder.blank?
                next if (Time.now - start < 0.5) && !Rails.env.test?
                start = Time.now
              end

              Discourse.redis.expire(redis_stream_key, 60)

              publish_update(reply_post, { raw: raw })
            end
          end

        return if reply.blank?

        if stream_reply
          # land the final message prior to saving so we don't clash
          reply_post.cooked = PrettyText.cook(reply)
          publish_final_update(reply_post)

          reply_post.revise(
            bot.bot_user,
            { raw: reply },
            skip_validations: true,
            skip_revision: true,
          )
        else
          reply_post =
            PostCreator.create!(
              reply_user,
              topic_id: post.topic_id,
              raw: reply,
              skip_validations: true,
              post_type: post_type,
            )
        end

        # we do not need to add a custom prompt for a single reply
        if new_custom_prompts.length > 1
          reply_post.post_custom_prompt ||= reply_post.build_post_custom_prompt(custom_prompt: [])
          prompt = reply_post.post_custom_prompt.custom_prompt || []
          prompt.concat(new_custom_prompts)
          reply_post.post_custom_prompt.update!(custom_prompt: prompt)
        end

        # since we are skipping validations and jobs we
        # may need to fix participant count
        if reply_post.topic.private_message? && reply_post.topic.participant_count < 2
          reply_post.topic.update!(participant_count: 2)
        end

        reply_post
      ensure
        publish_final_update(reply_post) if stream_reply
        if reply_post && post.post_number == 1 && post.topic.private_message?
          title_playground(reply_post)
        end
      end

      def available_bot_usernames
        @bot_usernames ||=
          AiPersona.joins(:user).pluck(:username).concat(available_bot_users.map(&:username))
      end

      def available_bot_user_ids
        @bot_ids ||= AiPersona.joins(:user).pluck("users.id").concat(available_bot_users.map(&:id))
      end

      private

      def available_bot_users
        @available_bots ||=
          User.joins("INNER JOIN llm_models llm ON llm.user_id = users.id").where(active: true)
      end

      def publish_final_update(reply_post)
        return if @published_final_update
        if reply_post
          publish_update(reply_post, { cooked: reply_post.cooked, done: true })
          # we subscribe at position -2 so we will always get this message
          # moving all cooked on every page load is wasteful ... this means
          # we have a benign message at the end, 2 is set to ensure last message
          # is delivered
          publish_update(reply_post, { noop: true })
          @published_final_update = true
        end
      end

      def can_attach?(post)
        return false if bot.bot_user.nil?
        return false if post.topic.private_message? && post.post_type != Post.types[:regular]
        return false if (SiteSetting.ai_bot_allowed_groups_map & post.user.group_ids).blank?

        true
      end

      def schedule_bot_reply(post)
        persona_id =
          DiscourseAi::AiBot::Personas::Persona.system_personas[bot.persona.class] ||
            bot.persona.class.id
        ::Jobs.enqueue(
          :create_ai_reply,
          post_id: post.id,
          bot_user_id: bot.bot_user.id,
          persona_id: persona_id,
        )
      end

      def context(topic)
        {
          site_url: Discourse.base_url,
          site_title: SiteSetting.title,
          site_description: SiteSetting.site_description,
          time: Time.zone.now,
          participants: topic.allowed_users.map(&:username).join(", "),
        }
      end

      def publish_update(bot_reply_post, payload)
        payload = { post_id: bot_reply_post.id, post_number: bot_reply_post.post_number }.merge(
          payload,
        )
        MessageBus.publish(
          "discourse-ai/ai-bot/topic/#{bot_reply_post.topic_id}",
          payload,
          user_ids: bot_reply_post.topic.allowed_user_ids,
          max_backlog_size: 2,
          max_backlog_age: 60,
        )
      end
    end
  end
end
