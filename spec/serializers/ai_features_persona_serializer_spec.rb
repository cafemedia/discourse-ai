# frozen_string_literal: true

RSpec.describe AiFeaturesPersonaSerializer do
  fab!(:admin)
  fab!(:ai_persona)
  fab!(:group)
  fab!(:group_2) { Fabricate(:group) }

  describe "serialized attributes" do
    before do
      ai_persona.allowed_group_ids = [group.id, group_2.id]
      ai_persona.save!
    end

    context "when there is a persona with allowed groups" do
      let(:allowed_groups) do
        Group
          .where(id: ai_persona.allowed_group_ids)
          .pluck(:id, :name)
          .map { |id, name| { id: id, name: name } }
      end

      it "display every participant" do
        serialized = described_class.new(ai_persona, scope: Guardian.new(admin), root: nil)
        expect(serialized.id).to eq(ai_persona.id)
        expect(serialized.name).to eq(ai_persona.name)
        expect(serialized.system_prompt).to eq(ai_persona.system_prompt)
        expect(serialized.allowed_groups).to eq(allowed_groups)
        expect(serialized.enabled).to eq(ai_persona.enabled)
      end
    end
  end
end
