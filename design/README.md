# design/

Where this product's design assets and mockups live: wireframes, component
comps, brand tokens, flow diagrams, exported screens -- whatever the product's
UI work references. It has no build role (nothing here ships in an image); it is
the durable home for design source so it travels with the repo instead of a
separate drive.

Suggested layout (grow as needed):

```
design/
├── README.md          this file
├── mockups/           static comps / exported screens
├── flows/             user-flow + state diagrams
└── tokens/            color / type / spacing tokens the client consumes
```

The client (`../client/`) is the code that realizes these designs; keep the
source of a screen here and its implementation there.
