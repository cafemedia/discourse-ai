import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn, hash } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import Form from "discourse/components/form";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import AiToolTestModal from "./modal/ai-tool-test-modal";
import RagOptions from "./rag-options";
import RagUploader from "./rag-uploader";

export default class AiToolEditorForm extends Component {
  @service modal;
  @service siteSettings;
  @service dialog;
  @service router;
  @service toasts;

  @tracked uploadedFiles = [];
  @tracked isSaving = false;

  PARAMETER_TYPES = [
    { name: "string", id: "string" },
    { name: "number", id: "number" },
    { name: "boolean", id: "boolean" },
    { name: "array", id: "array" },
  ];

  get formData() {
    return {
      name: this.args.editingModel.name || "",
      tool_name: this.args.editingModel.tool_name || "",
      description: this.args.editingModel.description || "",
      summary: this.args.editingModel.summary || "",
      parameters: this.args.editingModel.parameters || [],
      script: this.args.editingModel.script || "",
      rag_uploads: this.args.editingModel.rag_uploads || [],
    };
  }

  @action
  async save(data) {
    this.isSaving = true;

    try {
      await this.args.model.save(data);

      this.toasts.success({
        data: { message: i18n("discourse_ai.tools.saved") },
        duration: 2000,
      });

      if (!this.args.tools.any((tool) => tool.id === this.args.model.id)) {
        this.args.tools.pushObject(this.args.model);
      }

      this.router.transitionTo(
        "adminPlugins.show.discourse-ai-tools.edit",
        this.args.model
      );
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.isSaving = false;
    }
  }

  @action
  delete() {
    return this.dialog.confirm({
      message: i18n("discourse_ai.tools.confirm_delete"),

      didConfirm: async () => {
        await this.args.model.destroyRecord();
        this.args.tools.removeObject(this.args.model);
        this.router.transitionTo("adminPlugins.show.discourse-ai-tools.index");
      },
    });
  }

  @action
  updateUploads(addItemToCollection, uploads) {
    const uniqueUploads = uploads.filter(
      (upload) => !this.uploadedFiles.some((file) => file.id === upload.id)
    );
    addItemToCollection("rag_uploads", uniqueUploads);
    this.uploadedFiles = [...this.uploadedFiles, ...uniqueUploads];
  }

  @action
  removeUpload(form, upload) {
    this.uploadedFiles = this.uploadedFiles.filter(
      (file) => file.id !== upload.id
    );
    form.set("rag_uploads", this.uploadedFiles);
  }

  @action
  openTestModal() {
    this.modal.show(AiToolTestModal, {
      model: {
        tool: this.args.editingModel,
      },
    });
  }

  currentParameterSelection(data, index) {
    return data.parameters[index].type;
  }

  get ragUploadsDescription() {
    return this.siteSettings.rag_images_enabled
      ? i18n("discourse_ai.rag.uploads.description_with_images")
      : i18n("discourse_ai.rag.uploads.description");
  }

  <template>
    <Form
      @onSubmit={{this.save}}
      @data={{this.formData}}
      class="ai-tool-editor"
      as |form data|
    >

      {{! NAME }}
      <form.Field
        @name="name"
        @title={{i18n "discourse_ai.tools.name"}}
        @validation="required|length:1,100"
        @format="large"
        @tooltip={{i18n "discourse_ai.tools.name_help"}}
        as |field|
      >
        <field.Input class="ai-tool-editor__name" />
      </form.Field>

      {{! TOOL NAME }}
      <form.Field
        @name="tool_name"
        @title={{i18n "discourse_ai.tools.tool_name"}}
        @validation="required|length:1,100"
        @format="large"
        @tooltip={{i18n "discourse_ai.tools.tool_name_help"}}
        as |field|
      >
        <field.Input class="ai-tool-editor__tool_name" />
      </form.Field>

      {{! DESCRIPTION }}
      <form.Field
        @name="description"
        @title={{i18n "discourse_ai.tools.description"}}
        @validation="required|length:1,1000"
        @format="full"
        @tooltip={{i18n "discourse_ai.tools.description_help"}}
        as |field|
      >
        <field.Textarea
          @height={{60}}
          class="ai-tool-editor__description"
          placeholder={{i18n "discourse_ai.tools.description_help"}}
        />
      </form.Field>

      {{! SUMMARY }}
      <form.Field
        @name="summary"
        @title={{i18n "discourse_ai.tools.summary"}}
        @validation="required|length:1,255"
        @format="large"
        @tooltip={{i18n "discourse_ai.tools.summary_help"}}
        as |field|
      >
        <field.Input class="ai-tool-editor__summary" />
      </form.Field>

      {{! PARAMETERS }}
      <form.Collection @name="parameters" as |collection index|>
        <div class="ai-tool-parameter">
          <form.Row as |row|>
            <row.Col @size={{6}}>
              <collection.Field
                @name="name"
                @title={{i18n "discourse_ai.tools.parameter_name"}}
                @validation="required|length:1,100"
                as |field|
              >
                <field.Input />
              </collection.Field>
            </row.Col>

            <row.Col @size={{6}}>
              <collection.Field
                @name="type"
                @title={{i18n "discourse_ai.tools.parameter_type"}}
                @validation="required"
                as |field|
              >
                <field.Menu
                  @selection={{this.currentParameterSelection data index}}
                  as |menu|
                >
                  {{#each this.PARAMETER_TYPES as |type|}}
                    <menu.Item
                      @value={{type.id}}
                      data-type={{type.id}}
                    >{{type.name}}</menu.Item>
                  {{/each}}
                </field.Menu>
              </collection.Field>
            </row.Col>
          </form.Row>

          <collection.Field
            @name="description"
            @title={{i18n "discourse_ai.tools.parameter_description"}}
            @validation="required|length:1,1000"
            as |field|
          >
            <field.Input class="ai-tool-editor__parameter-description" />
          </collection.Field>

          <form.Row as |row|>
            <row.Col @size={{4}}>
              <collection.Field @name="required" @title="Required" as |field|>
                <field.Checkbox />
              </collection.Field>
            </row.Col>

            <row.Col @size={{4}}>
              <collection.Field @name="enum" @title="Enum" as |field|>
                <field.Checkbox />
              </collection.Field>
            </row.Col>

            <row.Col @size={{4}} class="ai-tool-parameter-actions">
              <form.Button
                @label="discourse_ai.tools.remove_parameter"
                @icon="trash-can"
                @action={{fn collection.remove index}}
                class="btn-danger"
              />
            </row.Col>
          </form.Row>
        </div>
      </form.Collection>

      <form.Button
        @icon="plus"
        @label="discourse_ai.tools.add_parameter"
        @action={{fn
          form.addItemToCollection
          "parameters"
          (hash name="" type="string" description="" required=false enum=false)
        }}
      />

      {{! SCRIPT }}
      <form.Field
        @name="script"
        @title={{i18n "discourse_ai.tools.script"}}
        @validation="required|length:1,100000"
        @format="full"
        as |field|
      >
        <field.Code @lang="javascript" @height={{600}} />
      </form.Field>

      {{! Uploads }}
      {{#if this.siteSettings.ai_embeddings_enabled}}
        <form.Field
          @name="rag_uploads"
          @title={{i18n "discourse_ai.rag.uploads.title"}}
          @tooltip={{this.ragUploadsDescription}}
          as |field|
        >
          <field.Custom>
            <RagUploader
              @target={{@editingModel}}
              @updateUploads={{fn this.updateUploads form.addItemToCollection}}
              @onRemove={{fn this.removeUpload form}}
              @allowImages={{@settings.rag_images_enabled}}
            />
            <RagOptions
              @model={{@editingModel}}
              @llms={{@llms}}
              @allowImages={{@settings.rag_images_enabled}}
            />
          </field.Custom>
        </form.Field>
      {{/if}}

      <form.Actions>
        {{#unless @isNew}}
          <form.Button
            @label="discourse_ai.tools.test"
            @action={{this.openTestModal}}
            class="ai-tool-editor__test-button"
          />

          <form.Button
            @label="discourse_ai.tools.delete"
            @icon="trash-can"
            @action={{this.delete}}
            class="btn-danger ai-tool-editor__delete"
          />
        {{/unless}}

        <form.Submit
          @label="discourse_ai.tools.save"
          class="ai-tool-editor__save"
        />
      </form.Actions>
    </Form>
  </template>
}
