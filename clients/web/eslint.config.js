// eslint.config.js -- the bare-ids client contract, baked into the shell from
// day one (epic znasllc-io/memql#2438, WS-A). Clients use BARE ids only;
// canonicalization is SERVER-SIDE. These rules make a canonical-id leak a lint
// error at author time.
//
// Mirrors the intent of the SPA-side rules A4 (znasllc-io/memql#2443) lands in
// the reference product. That branch was not yet pushed when this shell was
// authored, so these are the equivalent rules; reconcile the exact selector set
// with A4's config when it merges (delta noted in the B3 PR).
//
// The ONLY place canonical `v1:` ids may appear is the generated module
// (src/generated/, produced by the engine's sdk-gen over this repo's dsl/) --
// it is the DSL source of truth and is excluded below.

import tsParser from "@typescript-eslint/parser";

const bareIdRules = [
  {
    selector: "Literal[value=/^v1:/]",
    message:
      "Bare ids only: no canonical 'v1:'-prefixed id literal. Refer to a concept via src/generated/concepts.ts (Concepts / CDCTopics / CDCFilters).",
  },
  {
    selector: "TemplateElement[value.cooked=/v1:/]",
    message:
      "Bare ids only: no 'v1:' inside a template literal. Compose topics/filters with the generated topicFor / filterFor helpers.",
  },
  {
    selector: "CallExpression[callee.property.name='split'][arguments.0.value=':']",
    message:
      "Do not split an id on ':': ids on the wire are bare short slugs. Canonicalization is server-side; use the generated concept constants.",
  },
  {
    selector: "CallExpression[callee.property.name='lastIndexOf'][arguments.0.value=':']",
    message:
      "Do not parse an id by ':': ids on the wire are bare. Use the generated concept constants, not string surgery.",
  },
];

export default [
  { ignores: ["dist", "node_modules", "src/generated/**"] },
  {
    files: ["src/**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: "latest",
        sourceType: "module",
        ecmaFeatures: { jsx: true },
      },
    },
    rules: {
      "no-restricted-syntax": ["error", ...bareIdRules],
      "prefer-const": "error",
      eqeqeq: ["error", "smart"],
    },
  },
];
