/// Safe tools — read-only / internal, auto-allowed without phone approval.
/// SINGLE SOURCE OF TRUTH — used by hook binary (via #[path]) and parser (via crate import).
pub const SAFE_TOOLS: &[&str] = &[
    "Read", "Glob", "Grep",
    "TodoWrite", "TaskList", "TaskGet", "TaskCreate", "TaskUpdate", "TaskStop", "TaskOutput",
    "ExitPlanMode", "EnterPlanMode",
    "SendMessage", "TeamCreate", "TeamDelete", "Skill",
    "ToolSearch",
];
