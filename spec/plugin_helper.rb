# frozen_string_literal: true

module DiscourseAi::ChatBotHelper
  def toggle_enabled_bots(bots: [])
    models = LlmModel.all
    models = models.where("id not in (?)", bots.map(&:id)) if bots.present?
    models.update_all(enabled_chat_bot: false)

    bots.each { |b| b.update!(enabled_chat_bot: true) }
    DiscourseAi::AiBot::SiteSettingsExtension.enable_or_disable_ai_bots
  end

  def assign_fake_provider_to(setting_name)
    Fabricate(:fake_model).tap do |fake_llm|
      SiteSetting.public_send("#{setting_name}=", "custom:#{fake_llm.id}")
    end
  end
end

RSpec.configure do |config|
  config.include DiscourseAi::ChatBotHelper

  config.before(:suite) do
    if defined?(migrate_column_to_bigint)
      migrate_column_to_bigint(RagDocumentFragment, :target_id)
      migrate_column_to_bigint("ai_document_fragment_embeddings", "rag_document_fragment_id")
      migrate_column_to_bigint(ClassificationResult, :target_id)
    end
  end
end
