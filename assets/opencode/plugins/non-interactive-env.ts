import type { Plugin } from "@opencode-ai/plugin"

const plugin: Plugin = async (ctx) => ({
  "shell.env": async (input, output) => {
    output.env.GIT_EDITOR = ":"
    output.env.EDITOR = ":"
    output.env.GIT_SEQUENCE_EDITOR = ":"
    output.env.GIT_PAGER = "cat"
  },
})

export default plugin
