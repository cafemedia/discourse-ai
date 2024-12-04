# frozen_string_literal: true

RSpec.describe "AI Post helper", type: :system, js: true do
  fab!(:user) { Fabricate(:admin) }
  fab!(:non_member_group) { Fabricate(:group) }
  fab!(:topic)
  fab!(:post) do
    Fabricate(
      :post,
      topic: topic,
      raw:
        "I like to eat pie. It is a very good dessert. Some people are wasteful by throwing pie at others but I do not do that. I always eat the pie.",
    )
  end
  fab!(:post_2) do
    Fabricate(:post, topic: topic, raw: "La lluvia en España se queda principalmente en el avión.")
  end
  fab!(:post_3) do
    Fabricate(
      :post,
      topic: topic,
      raw: "The Toyota Supra delivrs 382 horsepwr makin it a very farst car.",
    )
  end
  let(:topic_page) { PageObjects::Pages::Topic.new }
  let(:post_ai_helper) { PageObjects::Components::AiPostHelperMenu.new }
  let(:fast_editor) { PageObjects::Components::FastEditor.new }

  before do
    Group.find_by(id: Group::AUTO_GROUPS[:admins]).add(user)
    assign_fake_provider_to(:ai_helper_model)
    SiteSetting.ai_helper_enabled = true
    sign_in(user)
  end

  def select_post_text(selected_post)
    topic_page.visit_topic(topic)
    page.execute_script(
      "var element = document.querySelector('#{topic_page.post_by_number_selector(selected_post.post_number)} .cooked p'); " +
        "var range = document.createRange(); " + "range.selectNodeContents(element); " +
        "var selection = window.getSelection(); " + "selection.removeAllRanges(); " +
        "selection.addRange(range);",
    )
  end

  context "when triggering AI helper in post" do
    it "shows the Ask AI button in the post selection toolbar" do
      select_post_text(post)
      expect(post_ai_helper).to have_post_selection_toolbar
      expect(post_ai_helper).to have_post_ai_helper
    end

    it "shows AI helper options after clicking the AI button" do
      select_post_text(post)
      post_ai_helper.click_ai_button
      expect(post_ai_helper).to have_no_post_selection_primary_buttons
      expect(post_ai_helper).to have_post_ai_helper_options
    end

    it "should not have the mobile post AI helper" do
      select_post_text(post)
      post_ai_helper.click_ai_button
      expect(post_ai_helper).to have_no_mobile_post_ai_helper
    end

    it "highlights the selected text after clicking the AI button and removes after closing" do
      select_post_text(post)
      post_ai_helper.click_ai_button
      expect(post_ai_helper).to have_highlighted_text
      find("article[data-post-id='#{post.id}']").click
      expect(post_ai_helper).to have_no_highlighted_text
    end

    it "allows post control buttons to still be functional after clicking the AI button" do
      select_post_text(post)
      post_ai_helper.click_ai_button
      topic_page.click_like_reaction_for(post)
      wait_for { post.reload.like_count == 1 }
      expect(post.like_count).to eq(1)
    end

    context "when using proofread mode" do
      let(:mode) { CompletionPrompt::PROOFREAD }
      let(:proofread_response) do
        "The Toyota Supra delivers 382 horsepower making it a very fast car."
      end

      it "pre-fills fast edit with proofread text" do
        skip("Test is flaky in CI, possibly some timing issue?") if ENV["CI"]
        select_post_text(post_3)
        post_ai_helper.click_ai_button
        DiscourseAi::Completions::Llm.with_prepared_responses([proofread_response]) do
          post_ai_helper.select_helper_model(mode)
          wait_for { fast_editor.has_content?(proofread_response) }
          expect(fast_editor).to have_content(proofread_response)
        end
      end
    end
  end

  context "when AI helper is disabled" do
    before { SiteSetting.ai_helper_enabled = false }

    it "does not show the Ask AI button in the post selection toolbar" do
      select_post_text(post)
      expect(post_ai_helper).to have_post_selection_toolbar
      expect(post_ai_helper).to have_no_post_ai_helper
    end
  end

  context "when user is not a member of the post AI helper allowed group" do
    before do
      SiteSetting.ai_helper_enabled = true
      SiteSetting.post_ai_helper_allowed_groups = non_member_group.id.to_s
    end

    it "does not show the Ask AI button in the post selection toolbar" do
      select_post_text(post)
      expect(post_ai_helper).to have_post_selection_toolbar
      expect(post_ai_helper).to have_no_post_ai_helper
    end
  end

  context "when triggering AI proofread through edit button" do
    let(:proofread_response) do
      "The Toyota Supra delivers 382 horsepower making it a very fast car."
    end

    it "pre-fills fast edit with proofread text" do
      skip("Test is flaky in CI, possibly some timing issue?") if ENV["CI"]
      select_post_text(post_3)
      find(".quote-edit-label").click
      DiscourseAi::Completions::Llm.with_prepared_responses([proofread_response]) do
        find(".btn-ai-suggest-edit", visible: :all).click
        wait_for { fast_editor.has_content?(proofread_response) }
        expect(fast_editor).to have_content(proofread_response)
      end
    end
  end

  context "when triggering post AI helper on mobile", mobile: true do
    it "should use the bottom modal instead of the popup menu" do
      select_post_text(post)
      post_ai_helper.click_ai_button
      expect(post_ai_helper).to have_mobile_post_ai_helper
    end
  end
end
