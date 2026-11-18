# rebar3_patina

A rebar3 plugin that builds Patina packages.

To use the Patina compiler, add the following to your `rebar.config`:

```erlang
%% Add the plugin.
{plugins, [rebar3_patina]}.

%% Add `patina_core` to your dependencies.
%% We recommend depending on version `">= 0.0.0"`.
{deps, [{patina_core, ">= 0.0.0"}]}.

%% A `Patina.toml` beside `rebar.config` is always compiled. `packages`
%% names the directories of other in-tree Patina packages. Default: `[]`.
% {patina_opts, [{packages, ["src/my_package", "src/my_helpers"]}]}.
```

For multiple Patina packages in the source tree, each is built after its dependencies.
Make sure the dependencies are listed in each `Patina.toml`!
The relationships between the packages of `patina_packages` should be specified as `path` deps:

```toml
[dependencies]
my_helpers = { path = "../my_helpers" }
```

Any other dependency will be resolved from `rebar.config`.
