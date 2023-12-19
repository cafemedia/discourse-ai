# frozen_string_literal: true

return if !defined?(DiscourseAutomation)

describe DiscourseAutomation do
  let(:automation) { Fabricate(:automation, script: "llm_report", enabled: true) }

  def add_automation_field(name, value, type: "text")
    automation.fields.create!(
      component: type,
      name: name,
      metadata: {
        value: value,
      },
      target: "script",
    )
  end

  it "can trigger via automation" do
    user = Fabricate(:user)

    add_automation_field("sender", user.username, type: "user")
    add_automation_field("receivers", [user.username], type: "users")
    add_automation_field("model", "gpt-4-turbo")
    add_automation_field("title", "Weekly report")

    DiscourseAi::Completions::Llm.with_prepared_responses(["An Amazing Report!!!"]) do
      automation.trigger!
    end

    pm = Topic.where(title: "Weekly report").first
    expect(pm.posts.first.raw).to eq("An Amazing Report!!!")
  end
end
