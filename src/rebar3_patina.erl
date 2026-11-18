-module(rebar3_patina).

-export([init/1]).

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    case lists:member(rebar3_patina_compiler, rebar_state:compilers(State)) of
        true -> {ok, State};
        false -> {ok, rebar_state:append_compilers(State, [rebar3_patina_compiler])}
    end.
