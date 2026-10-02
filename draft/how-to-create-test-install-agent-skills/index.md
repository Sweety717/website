---
title: "How to Create Agent Skills: Tools, Testing, and Installation"
date: "2026-10-02"
description: "A practical guide to creating, validating, testing, and installing Agent Skills in Claude Code, from SKILL.md to plugin eval."
authors:
  - "maks-danylenko"
image: "agent-skills-chalkboard.jpg"
categories:
  - "AI"
  - "Developer Tools"
canonical: "https://mavka.ai/blog/how-to-create-test-install-claude-skills"
---

> **In short.** Start with a task that keeps coming up and turn it into a Skill with `superpowers:writing-skills`. While creating it, test scenarios with and without the Skill, and validate the structure of `SKILL.md`. Then use the Skill on several real tasks. If it consistently helps, share it with your team through a Skills repository or a Plugin.

Creating your first Agent Skill is easy. Make a folder, put a `SKILL.md` file in it, and write a few instructions.

**The harder part is knowing whether that Skill actually works.**

The agent has to find it among dozens of other instructions, invoke it for the right request, ignore similar but irrelevant requests, follow its instructions, and produce a better result than it would without the Skill.

This guide covers tools for the full cycle: **creation, improvement, validation, testing, installation, and maintenance**.

## What a Skill is in practice

An Agent Skill is a folder containing instructions, reference material, and, if needed, executable scripts. Only one file is required: `SKILL.md`.

A minimal Skill looks like this:

```text
review-migration/
└── SKILL.md
```

```markdown
---
name: review-migration
description: Reviews database migrations for compatibility and rollback risks. Use when a user creates or changes a database migration.
---

Review the migration:

1. Check backward compatibility.
2. Identify locks or long-running operations.
3. Verify the rollback or roll-forward path.
4. Report only risks introduced by this migration.
```

The open [Agent Skills specification](https://agentskills.io/specification) requires the `name` and `description` fields. The description tells the agent when to read the full Skill for the task at hand.

That matters because of how Skills are loaded:

1. The agent sees the names and descriptions of available Skills. Names are always listed; when you have many Skills, Claude Code may drop descriptions of the least-used ones to fit its context budget.
2. The description helps it decide whether to read a particular Skill.
3. Once the Skill is activated, it reads the full `SKILL.md`.
4. It opens additional `references/`, `scripts/`, and `assets/` only when needed.

Anthropic calls this [progressive disclosure](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview). It manages context: the agent doesn't need the full text of every Skill in every request. It reads instructions for the relevant task and opens longer reference material when it needs it.

## Skill, AGENTS.md, or Plugin?

Not every instruction should become a Skill.

| Mechanism | When to use it |
| --- | --- |
| **AGENTS.md** | Short, always-on context: project structure, working commands, non-obvious architecture decisions, and links to detailed rules |
| **Skill** | A repeatable process or knowledge needed only for a particular type of task |
| **Plugin** | A collection of Skills with agents, Hooks, MCP servers, configuration, or its own versioning lifecycle |
| **MCP server** | Standardized access to an external system, data, or API |
| **Hook** | A predefined action triggered by an event, such as running a formatter after an edit |

<details>
<summary>Why Skills once started replacing MCP integrations, and what changed</summary>

Large MCP integrations used to load descriptions for every tool into each request. A few servers could occupy a substantial share of the context window. That led people to replace narrow integrations with Skills containing CLI commands: the agent would read the instructions only when it needed them.

Modern [tool search with deferred loading](https://platform.claude.com/docs/en/agents-and-tools/tool-use/manage-tool-context) has changed that trade-off. Descriptions of unused MCP tools no longer have to be included in the initial request: the agent can find the tool it needs and load its description on demand. That makes discovery more similar to Skills, though their roles remain different: a Skill provides a process and knowledge, while an MCP server performs an external action or returns data.

</details>

> A good sign that you need a new Skill: you're pasting the same checklist into a chat or explaining the same process to a new session for the third time.

## Tools for creating Skills

### 1. The agent itself

You don't need a separate generator. Anthropic's official [authoring guide](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices) recommends completing a real task from start to finish in a normal agent session, then asking the agent to extract the repeatable process into a Skill.

That's a better starting point than inventing a universal Skill from scratch. Real work quickly shows you:

- which context you keep repeating;
- where the agent makes the wrong decision;
- what belongs in instructions and what would work better as a script;
- which examples and edge cases you need.

Your initial request can be simple:

```text
Turn the process we just followed into an Agent Skill.
Keep only the required process in SKILL.md.
Move long reference material to references/.
Add examples of requests that should and should not trigger the Skill.
```

### 2. skill-creator or superpowers:writing-skills

Once you have a draft, you can use the [official skill-creator](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/skill-creator). It helps create and edit Skills, build test scenarios, compare results against an initial run without the Skill, and perform a blind A/B comparison of two versions.

Install it from the official Marketplace:

```text
/plugin install skill-creator@claude-plugins-official
```

After installation, you can ask the agent:

```text
Evaluate my review-migration Skill using skill-creator.
```

For creating Skills, I recommend Codex and [superpowers:writing-skills](https://github.com/obra/superpowers/blob/main/skills/writing-skills/SKILL.md). Its principle is stricter: first give the agent a real scenario without the Skill and record a specific failure; then write the smallest useful Skill, repeat the same scenario, and check whether its behavior changed. **If the agent consistently completes the task correctly without the Skill, a new Skill may have no purpose.**

That's enough for an early version. You don't need a CI system for an instruction you haven't even used twice.

## Three different kinds of checks

The word "validation" often hides three different questions.

`superpowers:writing-skills` adds a preliminary step: run a scenario without the Skill, put the agent under pressure, and observe how it behaves without extra instructions. This tests the premise itself. If the baseline run already succeeds, the Skill adds nothing; if it fails, you can see the specific behavior you need to change.

### 1. Is the structure valid?

For a portable Skill, use the validator for the open specification:

```bash
skills-ref validate ./review-migration
```

It checks the frontmatter and naming rules.

In Claude Code, you can validate project Skills like this:

```bash
claude plugin validate .claude/skills
```

Or validate your user-level Skills, agents, and commands (this does not check settings or Hooks):

```bash
claude plugin validate ~/.claude
```

According to the [Claude Code documentation](https://code.claude.com/docs/en/plugin-marketplaces#validate-a-plugin-or-a-directory-without-a-manifest), the validator finds problems with YAML, metadata, and Plugin structure. This checks syntax and schema. **A successful result doesn't mean the agent will choose the Skill at the right time.**

### 2. Does the Skill trigger?

Give this check to `superpowers:writing-skills` while creating the Skill. Include real requests that should trigger it and similar-sounding requests that should not. `superpowers:writing-skills` will run the scenarios and show whether the agent finds the instructions at the right moment.

If the Skill doesn't trigger, or triggers when it shouldn't, refine its `description` and repeat the check. If it triggers but doesn't help, revisit the main instructions and supporting files.

### 3. Did the result improve?

For a Skill packaged as a Plugin, Claude Code has a separate testing tool (it requires Claude Code v2.1.269 or later):

```bash
claude plugin eval init
claude plugin eval .
```

[Claude plugin eval](https://code.claude.com/docs/en/plugin-evals) runs each scenario in an isolated session several times with and without the Plugin. Graders can check text, tool calls, action order, created files, or criteria assessed by an LLM. The difference between `WITH` and `W/OUT` shows the Plugin's contribution, rather than just the base model's ability to complete the task.

This is useful for Skills that a team versions, shares, or uses in a critical process. The runs make real model calls. By default, each scenario runs three times with the Plugin and three times without it, so a suite costs both time and money.

One detail matters: `skill-creator` and `claude plugin eval` use different test formats. The former is useful for improving one Skill through a conversation. The latter is better suited to Plugins, regression suites, and CI.

## What /skill-doctor tells you

`/skill-doctor` answers a different question: which Skills consume context but are rarely used?

It shows how much context descriptions occupy, which Skills have never been invoked, and which Plugins haven't been used for a while. That helps remove noise from a large library. But `/skill-doctor` doesn't assess instruction quality or replace behavior checks.

## How to install a Skill in a project

The simplest option is to add it manually:

```bash
mkdir -p .claude/skills/review-migration
```

Then create `.claude/skills/review-migration/SKILL.md` and commit the folder. The Skill will load in sessions for that repository.

For a personal Skill that you need across all your local projects:

```text
~/.claude/skills/review-migration/SKILL.md
```

In a monorepo, you can put a Skill in `<package>/.claude/skills/`. It will apply to work in that subtree.

If a Skill is published in a Git repository and supports the open ecosystem:

```bash
npx skills add owner/repository --skill review-migration -a claude-code
```

Add `-g` to install it globally instead of in the current project.

## When you need a Plugin and Marketplace

A standalone Skill works well within one repository. Use a Plugin when you want to:

- distribute several Skills as one package;
- add agents, Hooks, or MCP configuration;
- have a namespace such as `/database-tools:review-migration`;
- version and update the package;
- attach a formal test suite.

A minimal Plugin structure:

```text
database-tools/
├── .claude-plugin/
│   └── plugin.json
└── skills/
    └── review-migration/
        └── SKILL.md
```

You can test the Plugin locally with:

```bash
claude --plugin-dir ./database-tools
claude plugin validate ./database-tools
```

To share it, a team can create a private Marketplace, add it at the project level, and install the Plugin from there. The official [Marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces) supports a GitHub repository, Git URL, remote `marketplace.json`, and local path.

```text
/plugin marketplace add acme/database-plugins
/plugin install database-tools@acme-database-plugins
```

The CLI equivalent supports `user`, `project`, and `local` scopes. At the `project` level, configuration is written to the repository so the team shares one Plugin source.

## Check third-party Skills before installing them

There has never been an easier way for agent instructions to spread widely. One repository and one install command can put someone else's `SKILL.md`, scripts, or entire Plugin into hundreds of working environments.

A Skill gives instructions to an agent with access to files and tools. A Plugin can also contain Hooks, MCP servers, and executable scripts. Popularity in a catalog doesn't automatically make that code safe.

Before installing, check:

- the contents of `SKILL.md` and every reference to `scripts/`;
- `allowed-tools` and shell commands;
- Hooks and MCP configuration inside the Plugin;
- whether the Skill requests secrets, unnecessary permissions, or network access;
- the repository owner, license, change history, and update process.

For a team library, pin a reviewed version, run validation in CI, and update Skills as deliberately as you update other dependencies.

## A practical process without extra infrastructure

For your first Skill:

1. Complete a real task without the Skill.
2. Record the baseline result: exactly where the agent failed or behaved inconsistently.
3. Ask the agent to extract the repeatable process.
4. Write three requests that should trigger the Skill and three similar but irrelevant requests.
5. Put the Skill in `.claude/skills`.
6. Validate its structure.
7. Repeat the baseline scenario in a new session with the Skill.

For a Skill used by a team:

1. Add more real scenarios.
2. Move unstable steps into deterministic scripts.
3. Package the Skill as a Plugin.
4. Add `claude plugin eval`.
5. Run the suite after Skill changes and after switching to a new model.
6. Periodically check `/skill-doctor` and disable what you don't use.

## The main mistake: testing the file instead of behavior

The weakest success criterion is: "The agent read the Skill, and its answer looks fine."

Better questions are:

- Did the Skill trigger without its name being mentioned?
- Did it stay quiet for a similar but irrelevant request?
- Did it improve the result compared with the baseline run?
- Did it reduce repeated explanations?
- Can you reproduce the result in a new session?
- Does the new version fix a specific failure without breaking existing scenarios?

A Skill isn't a document you write once and polish. It's an executable part of the agent workflow. Treat it like code: keep it short, test it on real scenarios, version it, and don't confuse valid syntax with the right behavior.

## Try it in practice

We've published a set of [Agent Skills for generating effective unit tests](https://github.com/mavka-ai/unit-tests-skills), including Java with JUnit 5, Mockito, and AssertJ. Install it in your project and try it on real code.

## Sources

- [Claude Code — Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Claude Code — Test plugins with evals](https://code.claude.com/docs/en/plugin-evals)
- [Claude Code — Create plugins](https://code.claude.com/docs/en/plugins)
- [Claude Code — Plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)
- [Agent Skills specification](https://agentskills.io/specification)
- [Anthropic — Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Anthropic — Manage tool context](https://platform.claude.com/docs/en/agents-and-tools/tool-use/manage-tool-context)
- [Anthropic — skill-creator](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/skill-creator)
- [Superpowers — writing-skills](https://github.com/obra/superpowers/blob/main/skills/writing-skills/SKILL.md)
- [Vercel Labs — skills CLI](https://github.com/vercel-labs/skills)
