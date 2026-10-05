// Workaround: the saga vLLM gateway's Qwen3.5 chat template fails with a 500
// ("Failed to communicate with the upstream service") when a conversation
// contains more than one system message. opencode normally sends several
// (main prompt + injected blocks like <date-awareness>), so merge them all
// into a single system message before the request is built.
export default async function () {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      // Only needed for the saga Qwen3.5-122B-A10B-NVFP4 deployment, whose
      // chat template 500s on multiple system messages. Scoped to this exact
      // model ID so replacing/rotating the model (e.g. to Qwen 3.8) makes
      // this a no-op; delete the plugin once the backend is fixed.
      if (input?.model?.id !== "<model>") return
      const s = output?.system
      if (Array.isArray(s) && s.length > 1) {
        const merged = s
          .filter((x) => typeof x === "string" && x.trim() !== "")
          .join("\n\n")
        s.length = 0
        s.push(merged)
      }
    },
  }
}
