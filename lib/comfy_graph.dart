/// Parsing layer for ComfyUI **UI-format** workflows.
///
/// A UI workflow is what the ComfyUI frontend saves: `nodes`, `links` and,
/// when subgraphs are used, `definitions.subgraphs`. `POST /prompt` however
/// only accepts the **API format**: a flat map of
/// `node_id -> {class_type, inputs}` where every input is either a literal or
/// a `[node_id, slot]` link.
///
/// The official frontend produces that map in the browser through
/// `app.graphToPrompt()`. A desktop client owns no graph, so the expansion has
/// to happen here. This library is that expansion, plus the parameter
/// extraction that turns a workflow into an editable form.
library;

export 'src/graph/api_prompt.dart';
export 'src/graph/graph_expansion_error.dart';
export 'src/graph/node_definition.dart';
export 'src/graph/parameter.dart';
export 'src/graph/parameter_extractor.dart';
export 'src/graph/prompt_patcher.dart';
export 'src/graph/ui_workflow.dart';
export 'src/graph/workflow_expander.dart';
