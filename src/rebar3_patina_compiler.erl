-module(rebar3_patina_compiler).
-moduledoc """
Builds the Patina packages of an app with `patina build`.

The root-level `Patina.toml` package is always built.
In-tree packages have to be named explicitly through `{patina_opts, [{packages, Dirs}]}`.
""".

-behaviour(rebar_compiler).
-export([context/1, needed_files/4, dependencies/3, compile/4, clean/2]).

-define(MANIFEST, "Patina.toml").

-record(package, {name :: binary(), deps :: [binary()]}).

context(AppInfo) ->
    #{
        src_dirs => [],
        include_dirs => [],
        src_ext => ".toml",
        out_mappings => [{".beam", rebar_app_info:ebin_dir(AppInfo)}]
    }.

dependencies(_Source, _SourceDir, _InDirs) ->
    [].

needed_files(_Graph, _FoundFiles, _Mappings, AppInfo) ->
    case is_extra_src_dir(AppInfo) of
        % Avoid compiling the packages again into the `extra_src_dirs` pseudo-app's ebin.
        true -> {{[], []}, {[], []}};
        false -> needed_packages(AppInfo)
    end.

needed_packages(AppInfo) ->
    maybe
        [_ | _] = Roots ?= package_dirs(AppInfo),
        check_core_dependency(AppInfo),
        Packages = #{Dir => fetch_package_details(Dir, AppInfo) || Dir <- Roots},
        delete_undeclared_packages_outputs(Packages, AppInfo),
        Opts = [
            {incremental_dir, incremental_dir(AppInfo)},
            {names, #{manifest(Dir) => Name || Dir := #package{name = Name} <- Packages}}
        ],
        {{[], Opts}, {topsort(Packages), Opts}}
    else
        [] = _Roots ->
            delete_all_packages_outputs(AppInfo),
            {{[], []}, {[], []}}
    end.

compile(Manifest, Mappings, _Config, Opts) ->
    {".beam", EbinDir} = lists:keyfind(".beam", 1, Mappings),
    #{Manifest := Name} = proplists:get_value(names, Opts),
    {ok, Cwd} = file:get_cwd(),
    Result = with_error_report(fun() ->
        patina:build([
            {dir, filename:dirname(Manifest)},
            {root, patina_root()},
            {out_dir, EbinDir},
            {incremental_dir, proplists:get_value(incremental_dir, Opts)},
            {emit, [meta, beam]},
            {lib_dir, lib_dirs()},
            {remap_path_prefix, {Cwd, ""}},
            {env, [{"PATINA_BOOTSTRAP", "1"} || Name =:= ~"core"]}
        ])
    end),
    case Result of
        {ok, Diagnostics} -> {ok, render_diagnostics(Diagnostics)};
        {error, Diagnostics} -> {error, render_diagnostics(Diagnostics), []}
    end.

clean(_Files, AppInfo) ->
    delete_all_packages_outputs(AppInfo).

package_dirs(AppInfo) ->
    AppDir = rebar_app_info:dir(AppInfo),
    PatinaOpts = rebar_app_info:get(AppInfo, patina_opts, []),
    Listed =
        case proplists:get_value(packages, PatinaOpts, []) of
            Packages when is_list(Packages) -> [filename:join(AppDir, Dir) || Dir <- Packages];
            Other -> rebar_api:abort("`packages` in `patina_opts` isn't a list: ~p", [Other])
        end,
    lists:uniq([AppDir || filelib:is_regular(manifest(AppDir))] ++ Listed).

-doc """
Check if we're in `extra_src_dir` special-case build by checking its side effect on `AppInfo`.
""".
is_extra_src_dir(AppInfo) ->
    rebar_app_info:ebin_dir(AppInfo) =/=
        filename:join(rebar_app_info:out_dir(AppInfo), "ebin").

check_core_dependency(AppInfo) ->
    Deps = rebar_app_info:get(AppInfo, deps, []),
    CoreDep = lists:search(
        fun
            (patina_core) -> true;
            (Dep) when element(1, Dep) =:= patina_core -> true;
            (_) -> false
        end,
        Deps
    ),

    case code:which(patina) of
        non_existing when CoreDep =:= false ->
            rebar_api:abort(
                "~ts requires `patina_core` in its `deps` list to compile Patina files.",
                [rebar_app_info:name(AppInfo)]
            );
        non_existing ->
            rebar_api:abort(
                "BUG: ~ts declares `patina_core` dependency, but it's not loaded during Patina compilation",
                [rebar_app_info:name(AppInfo)]
            );
        _ ->
            ok
    end,

    case CoreDep of
        {value, {patina_core, Requirement}} when is_list(Requirement); is_binary(Requirement) ->
            case re:run(Requirement, ~B"^\s*>=?\s*\S+\s*$", [{capture, none}]) of
                match ->
                    ok;
                nomatch ->
                    rebar_api:warn(
                        """
                        ~ts requires patina_core with a different matcher than `>=`: "~ts".
                        The installed Patina compiler version is used regardless of this constraint.
                        Only depend on `{patina_core, ">= a.b.c"}` to preserve compatibility
                        with future compiler updates.
                        """,
                        [rebar_app_info:name(AppInfo), Requirement]
                    )
            end;
        _Other ->
            ok
    end.

fetch_package_details(Dir, AppInfo) ->
    case with_error_report(fun() -> patina:print([package, dependencies], [{dir, Dir}]) end) of
        {ok, #{package := #{name := Name}, dependencies := Dependencies}} ->
            #package{name = Name, deps = [Dep || #{name := Dep} <:- Dependencies]};
        {error, Diagnostics} ->
            rebar_compiler:report(render_diagnostics(Diagnostics)),
            Source = rebar_compiler:format_error_source(
                manifest(Dir), rebar_app_info:opts(AppInfo)
            ),
            rebar_api:abort("Reading ~ts failed", [Source])
    end.

topsort(Packages) ->
    ByName = #{Name => manifest(Dir) || Dir := #package{name = Name} <- Packages},
    % An edge goes from a package to one it depends on.
    Graph = digraph:new(),
    try
        _ = [digraph:add_vertex(Graph, Name) || Name := _ <- ByName],
        _ = [
            digraph:add_edge(Graph, Name, DepName)
         || _ := #package{name = Name, deps = Deps} <- Packages,
            DepName <- Deps,
            % `false`: a dependency that isn't an internal package of this app.
            is_map_key(DepName, ByName)
        ],
        case digraph_utils:cyclic_strong_components(Graph) of
            [] ->
                [maps:get(Name, ByName) || Name <- lists:reverse(digraph_utils:topsort(Graph))];
            [[Package | _] | _] ->
                rebar_api:abort("Patina packages depend on each other in a cycle: ~ts", [
                    lists:join(" -> ", digraph:get_short_cycle(Graph, Package))
                ])
        end
    after
        digraph:delete(Graph)
    end.

delete_all_packages_outputs(AppInfo) ->
    delete_undeclared_packages_outputs(#{}, AppInfo).

-doc """
Cleans every package that was built, but is no longer declared.
""".
delete_undeclared_packages_outputs(DeclaredPackages, AppInfo) ->
    DeclaredPackageNames = #{Name => [] || _ := #package{name = Name} <- DeclaredPackages},

    BuiltPackageNames =
        case file:list_dir(incremental_dir(AppInfo)) of
            {ok, Dirs} -> Dirs;
            {error, _Reason} -> []
        end,

    lists:foreach(
        fun(BuiltPackageName) ->
            case is_map_key(rebar_utils:to_binary(BuiltPackageName), DeclaredPackageNames) of
                true -> ok;
                false -> delete_package_outputs(BuiltPackageName, AppInfo)
            end
        end,
        BuiltPackageNames
    ).

delete_package_outputs(Name, AppInfo) ->
    rebar_api:debug("Cleaning the removed Patina package ~ts", [Name]),
    PackageDir = incremental_dir(AppInfo, Name),
    EbinDir = rebar_app_info:ebin_dir(AppInfo),

    % All the stuff that landed in the shared `ebin` directory...
    case file:read_file(filename:join(PackageDir, "files")) of
        {ok, Contents} ->
            OutFiles = string:split(Contents, "\n", all),
            lists:foreach(
                fun
                    (<<>>) -> ok;
                    (OutFile) -> file:delete(filename:join(EbinDir, OutFile))
                end,
                OutFiles
            );
        {error, _Reason} ->
            ok
    end,

    % ...then the incremental dir.
    _ = file:del_dir_r(PackageDir),
    ok.

manifest(Dir) ->
    filename:join(Dir, ?MANIFEST).

lib_dirs() ->
    [Dir || Dir <- code:get_path(), filelib:wildcard("lib*.rmeta", Dir) =/= []].

patina_root() ->
    filename:dirname(code:lib_dir(patina_core)).

with_error_report(Fun) ->
    try
        Fun()
    catch
        error:#{'__struct__' := patina_error, message := Message} ->
            rebar_api:abort("~ts", [string:trim(Message, trailing)])
    end.

render_diagnostics(Diagnostics) ->
    [string:trim(Rendered, trailing) || #{rendered := Rendered} <:- Diagnostics].

incremental_dir(AppInfo) ->
    filename:join([
        rebar_dir:local_cache_dir(rebar_app_info:out_dir(AppInfo)),
        ?MODULE,
        rebar_app_info:name(AppInfo)
    ]).

incremental_dir(AppInfo, PackageName) ->
    filename:join([incremental_dir(AppInfo), PackageName]).
