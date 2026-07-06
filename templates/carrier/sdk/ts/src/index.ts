// @__PRODUCT_ORG__/__PRODUCT__-sdk
//
// The memQL runtime core (@znasllc-io/memql-sdk-core) re-exported, plus
// the generated __PRODUCT__ typed query/mutation/logic methods layered onto
// QueryClient. Importing this module runs the generated prototype
// augmentations as a side effect, so conn.query.queryActiveSpaces(...),
// conn.query.mutationCreateSpace(...), etc. are available at runtime.
//
// The generated surface under ./generated is produced from
// `core DSL + dsl/__PRODUCT__` by `go run ./scripts/sdk-gen`. DO NOT EDIT
// those files by hand.

export * from "@znasllc-io/memql-sdk-core";

import "./generated/generated_queries.js";
import "./generated/generated_mutations.js";
import "./generated/generated_logics.js";
import "./generated/generated_builtins.js";
