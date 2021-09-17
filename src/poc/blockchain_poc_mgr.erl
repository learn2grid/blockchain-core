%%%-------------------------------------------------------------------
%%% @doc
%%% listens for block events, inspects the POCs in the block metadata
%%% and for each of our own keys which made it into the block
%%% kick off a POC
%%% @end
%%%-------------------------------------------------------------------
-module(blockchain_poc_mgr).

-behaviour(gen_server).

-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(ACTIVE_POCS, active_pocs).
-define(KEYS, keys).
-define(POC_TIMEOUT, 4).
-define(ADDR_HASH_FP_RATE, 1.0e-9).

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    make_ets_table/0,
    cached_poc_key/1,
    save_poc_keys/2,
    check_target/3,
    report/4,
    active_pocs/0,
    local_poc_key/1
]).
%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ------------------------------------------------------------------
%% record defs and macros
%% ------------------------------------------------------------------
-record(addr_hash_filter, {
    start :: pos_integer(),
    height :: pos_integer(),
    byte_size :: pos_integer(),
    salt :: binary(),
    bloom :: bloom_nif:bloom()
}).

-record(poc_key_data, {
    receive_height :: non_neg_integer(),
    keys :: keys()
}).

-record(local_poc, {
    onion_key_hash :: binary(),
    block_hash :: binary() | undefined,
    keys :: keys() | undefined,
    target :: libp2p_crypto:pubkey_bin(),
    onion :: binary() | undefined,
    secret :: binary() | undefined,
    responses = #{},
    challengees = [] :: [libp2p_crypto:pubkey_bin()],
    packet_hashes = [] :: [{libp2p_crypto:pubkey_bin(), binary()}],
    start_height :: non_neg_integer()
}).

-record(state, {
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    chain :: undefined | blockchain:blockchain(),
    ledger :: undefined | blockchain:ledger(),
    sig_fun :: undefined | libp2p_crypto:sig_fun(),
    pub_key = undefined :: undefined | libp2p_crypto:pubkey_bin(),
    addr_hash_filter :: undefined | #addr_hash_filter{}
}).
-type state() :: #state{}.
-type keys() :: #{secret => libp2p_crypto:privkey(), public => libp2p_crypto:pubkey()}.
-type poc_key() :: binary().
-type cached_poc_key_type() :: {POCKey :: poc_key(), POCKeyData :: #poc_key_data{}}.

-type local_poc() :: #local_poc{}.
-type local_pocs() :: [local_poc()].
-type local_poc_key() :: binary().

-export_type([keys/0, local_poc_key/0, cached_poc_key_type/0, local_poc/0, local_pocs/0]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------

-spec local_poc_key(local_poc()) -> local_poc_key().
local_poc_key(LocalPoC) ->
    LocalPoC#local_poc.onion_key_hash.

-spec start_link(#{}) -> {ok, pid()}.
start_link(Args) when is_map(Args) ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []) of
        {ok, Pid} ->
            %% if we have an ETS table reference, give ownership to the new process
            %% we likely are the `heir', so we'll get it back if this process dies
            case maps:find(tab1, Args) of
                error ->
                    ok;
                {ok, Tab1} ->
                    true = ets:give_away(Tab1, Pid, undefined)
            end,
            {ok, Pid};
        Other ->
            Other
    end.

-spec make_ets_table() -> ok.
make_ets_table() ->
    Tab1 = ets:new(
        ?KEYS,
        [
            named_table,
            public,
            {heir, self(), undefined}
        ]
    ),
    Tab1.

-spec save_poc_keys(CurHeight :: non_neg_integer(), [keys()]) -> ok.
save_poc_keys(CurHeight, KeyList) ->
    %% these are the keys generated by this validator and submitted in the block
    %% either none or a subset of these will actually make it to the block
    %% we dont obviously know which may make it so we cache them all here
    %% push each key set to ets with a hash of the public key as key
    %% each new block we will then check if any of our cached keys made it into the block
    %% and if so retrieve the private key for each
    [
        begin
            #{public := PubKey} = Keys,
            OnionKeyHash = crypto:hash(sha256, libp2p_crypto:pubkey_to_bin(PubKey)),
            POCKeyRec = #poc_key_data{receive_height = CurHeight, keys = Keys},
            lager:info("caching local poc keys with hash ~p", [OnionKeyHash]),
            cache_poc_key(OnionKeyHash, POCKeyRec)
        end
        || Keys <- KeyList
    ],
    ok.

-spec cached_poc_key(poc_key()) -> {ok, cached_poc_key_type()} | false.
cached_poc_key(ID) ->
    case ets:lookup(?KEYS, ID) of
        [Res] -> {ok, Res};
        _ -> false
    end.

active_pocs() ->
    gen_server:call(?MODULE, {active_pocs}).

-spec check_target(
    Challengee :: libp2p_crypto:pubkey_bin(),
    BlockHash :: binary(),
    OnionKeyHash :: binary()
) -> false | {true, binary()} | {error, any()}.
check_target(Challengee, BlockHash, OnionKeyHash) ->
    %% TODO: try to get this to operate in caller context rather than a blocking call to the mgr
    %%       barrier to doing so atm is need to have the rocks db and cf handles
    %%       maybe use a shadow ets cache to store the active POCs
    gen_server:call(?MODULE, {check_target, Challengee, BlockHash, OnionKeyHash}).

report(Report, OnionKeyHash, Peer, P2PAddr) ->
    gen_server:cast(?MODULE, {Report, OnionKeyHash, Peer, P2PAddr}).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(_Args) ->
    ok = blockchain_event:add_handler(self()),
    erlang:send_after(500, self(), init),
    {ok, PubKey, SigFun, _ECDHFun} = blockchain_swarm:keys(),
    SelfPubKeyBin = libp2p_crypto:pubkey_to_bin(PubKey),
    DB = blockchain_poc_mgr_db_owner:db(),
    CF = blockchain_poc_mgr_db_owner:poc_mgr_cf(),
    {ok, #state{
        db = DB,
        cf = CF,
        sig_fun = SigFun,
        pub_key = SelfPubKeyBin
    }}.

handle_call({check_target, Challengee, BlockHash, OnionKeyHash}, _From, State = #state{chain = Chain}) ->
    %% TODO: do we really need the blockhash to be supplied and checked here?
    Res =
        case blockchain:get_block(BlockHash, Chain) of
            {ok, _Block} ->
                lager:info("*** check target with key ~p", [OnionKeyHash]),
                lager:info("*** check target challengee ~p", [Challengee]),
                case get_local_poc(OnionKeyHash, State) of
                    {error, _} ->
                        {error, <<"invalid_or_expired_poc">>};
                    {ok, #local_poc{block_hash = BlockHash, target = Challengee, onion = Onion}} ->
                        {true, Onion};
                    {ok, #local_poc{block_hash = BlockHash, target = _OtherTarget}} ->
                        false;
                    {ok, #local_poc{block_hash = _OtherBlockHash, target = _OtherTarget}} ->
                        {error, mismatched_block_hash}
                end;
            {error, not_found} ->
                {error, block_not_found}
        end,
    {reply, Res, State};
handle_call({active_pocs}, _From, State = #state{}) ->
    {reply, local_pocs(State), State};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast({{witness, Witness}, OnionKeyHash, Peer, _PeerAddr}, State) ->
    handle_witness(Witness, OnionKeyHash, Peer, State);
handle_cast({{receipt, Receipt}, OnionKeyHash, Peer, PeerAddr}, State) ->
    handle_receipt(Receipt, OnionKeyHash, Peer, PeerAddr, State);
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(init, #state{chain = undefined} = State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), init),
            {noreply, State};
        Chain ->
            Ledger = blockchain:ledger(Chain),
            SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
            {noreply, State#state{
                chain = Chain,
                ledger = Ledger,
                pub_key = SelfPubKeyBin
            }}
    end;
handle_info(init, State) ->
    {noreply, State};
handle_info(
    {blockchain_event, {add_block, BlockHash, Sync, _Ledger} = _Event},
    #state{chain = Chain} = State
) when Sync =:= false ->
    lager:info("received add block event, sync is ~p", [Sync]),
    State1 = maybe_init_addr_hash(State),
    case blockchain:get_block(BlockHash, Chain) of
        {ok, Block} ->
            %% save public data on each POC key found in the block to the ledger
            %% that way all validators have access to this public data
            %% however the validator which is running the POC will be the only node
            %% which has the secret
            ok = process_block_pocs(BlockHash, Block, State),
            %% take care of GC
            ok = purge_local_pocs(Block, State),
            BlockHeight = blockchain_block:height(Block),
            %% GC local pocs keys every 50 blocks
            case BlockHeight rem 50 == 0 of
                true ->
                    ok = purge_pocs_keys(Block);
                false ->
                    noop
            end,
            %% GC public pocs every 100 blocks
            case BlockHeight rem 100 == 0 of
                true ->
                    ok = purge_public_pocs(Block, Chain);
                false -> noop
            end;
        _ ->
            %% err what?
            noop
    end,
    {noreply, State1};
handle_info(
    {blockchain_event, {add_block, _BlockHash, Sync, _Ledger} = _Event},
    #state{chain = _Chain} = State
) when Sync =:= true ->
    lager:info("ignoring add block event, sync is ~p", [Sync]),
    {noreply, State};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%%%===================================================================
%%% breakout functions
%%%===================================================================
-spec handle_witness(
    Witness :: binary(),
    OnionKeyHash :: binary(),
    Address :: libp2p_crypto:pubkey_bin(),
    State :: #state{}
) -> false | {true, binary()} | {error, any()}.
handle_witness(Witness, OnionKeyHash, Peer, #state{chain = Chain} = State) ->
    lager:info("got witness ~p", [Witness]),
    %% Validate the witness is correct
    Ledger = blockchain:ledger(Chain),
    case validate_witness(Witness, Ledger) of
        false ->
            lager:warning("ignoring invalid witness ~p", [Witness]),
            {noreply, State};
        true ->
            %% get the local POC
            case get_local_poc(OnionKeyHash, State) of
                {error, _} ->
                    {noreply, State};
                {ok, #local_poc{packet_hashes = PacketHashes, responses = Response0} = POC} ->
                    PacketHash = blockchain_poc_witness_v1:packet_hash(Witness),
                    GatewayWitness = blockchain_poc_witness_v1:gateway(Witness),
                    %% check this is a known layer of the packet
                    case lists:keyfind(PacketHash, 2, PacketHashes) of
                        false ->
                            lager:warning("Saw invalid witness with packet hash ~p", [PacketHash]),
                            {noreply, State};
                        {GatewayWitness, PacketHash} ->
                            lager:warning("Saw self-witness from ~p", [GatewayWitness]),
                            {noreply, State};
                        _ ->
                            Witnesses = maps:get(PacketHash, Response0, []),
                            PerHopMaxWitnesses = blockchain_utils:poc_per_hop_max_witnesses(Ledger),
                            case erlang:length(Witnesses) >= PerHopMaxWitnesses of
                                true ->
                                    {noreply, State};
                                false ->
                                    %% Don't allow putting duplicate response in the witness list resp
                                    Predicate = fun({_, W}) ->
                                        blockchain_poc_witness_v1:gateway(W) == GatewayWitness
                                    end,
                                    Responses1 =
                                        case lists:any(Predicate, Witnesses) of
                                            false ->
                                                maps:put(
                                                    PacketHash,
                                                    lists:keystore(
                                                        Peer,
                                                        1,
                                                        Witnesses,
                                                        {Peer, Witness}
                                                    ),
                                                    Response0
                                                );
                                            true ->
                                                Response0
                                        end,
                                    UpdatedPOC = POC#local_poc{responses = Responses1},
                                    ok = write_local_poc(UpdatedPOC, State),
                                    {noreply, State}
                            end
                    end
            end
    end.

handle_receipt(Receipt, OnionKeyHash, Peer, PeerAddr, #state{chain = Chain} = State) ->
    lager:info("got receipt ~p", [Receipt]),
    Gateway = blockchain_poc_receipt_v1:gateway(Receipt),
    LayerData = blockchain_poc_receipt_v1:data(Receipt),
    Ledger = blockchain:ledger(Chain),
    case blockchain_poc_receipt_v1:is_valid(Receipt, Ledger) of
        false ->
            lager:warning("ignoring invalid receipt ~p", [Receipt]),
            {noreply, State};
        true ->
            %% get the POC data from the cache
            case get_local_poc(OnionKeyHash, State) of
                {error, _} ->
                    {noreply, State};
                {ok, #local_poc{challengees = Challengees, responses = Response0} = POC} ->
                    case lists:keyfind(Gateway, 1, Challengees) of
                        {Gateway, LayerData} ->
                            case maps:get(Gateway, Response0, undefined) of
                                undefined ->
                                    IsFirstChallengee =
                                        case hd(Challengees) of
                                            {Gateway, _} ->
                                                true;
                                            _ ->
                                                false
                                        end,
                                    %% compute address hash and compare to known ones
                                    %% TODO - This needs refactoring, wont work as is
                                    case check_addr_hash(PeerAddr, State) of
                                        true when IsFirstChallengee ->
                                            %% drop whole challenge because we should always be able to get the first hop's receipt
                                            %% TODO: delete the cached POC here?
                                            {noreply, State};
                                        true ->
                                            {noreply, State};
                                        undefined ->
                                            Responses1 = maps:put(
                                                Gateway,
                                                {Peer, Receipt},
                                                Response0
                                            ),
                                            UpdatedPOC = POC#local_poc{responses = Responses1},
                                            ok = write_local_poc(UpdatedPOC, State),
                                            {noreply, State};
                                        PeerHash ->
                                            Responses1 = maps:put(
                                                Gateway,
                                                {Peer,
                                                    blockchain_poc_receipt_v1:addr_hash(
                                                        Receipt,
                                                        PeerHash
                                                    )},
                                                Response0
                                            ),
                                            UpdatedPOC = POC#local_poc{responses = Responses1},
                                            ok = write_local_poc(UpdatedPOC, State),
                                            {noreply, State}
                                    end;
                                _ ->
                                    lager:warning("Already got this receipt ~p for ~p ignoring", [
                                        Receipt,
                                        Gateway
                                    ]),
                                    {noreply, State}
                            end;
                        {Gateway, OtherData} ->
                            lager:warning("Got incorrect layer data ~p from ~p (expected ~p)", [
                                Gateway,
                                OtherData,
                                Receipt
                            ]),
                            {noreply, State};
                        false ->
                            lager:warning("Got unexpected receipt from ~p", [Gateway]),
                            {noreply, State}
                    end
            end
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
initialize_poc(BlockHash, POCStartHeight, Keys, Vars, #state{chain = Chain, pub_key = Challenger} = State) ->
    Ledger = blockchain:ledger(Chain),
    #{public := OnionCompactKey, secret := {ecc_compact, POCPrivKey}} = Keys,
    POCPubKeyBin = libp2p_crypto:pubkey_to_bin(OnionCompactKey),
    #'ECPrivateKey'{privateKey = PrivKeyBin} = POCPrivKey,
    POCPrivKeyHash = crypto:hash(sha256, PrivKeyBin),
    OnionKeyHash = crypto:hash(sha256, POCPubKeyBin),
    lager:info("*** initializing POC at height ~p for local onion key hash ~p", [POCStartHeight, OnionKeyHash]),
    Entropy = <<OnionKeyHash/binary, BlockHash/binary>>,
    lager:info("*** entropy constructed using onionkeyhash ~p and blockhash ~p", [OnionKeyHash, BlockHash]),
    ZoneRandState = blockchain_utils:rand_state(Entropy),
    InitTargetRandState = blockchain_utils:rand_state(POCPrivKeyHash),
    lager:info("*** ZoneRandState ~p", [ZoneRandState]),
    lager:info("*** InitTargetRandState ~p", [InitTargetRandState]),
    case blockchain_poc_target_v4:target(Challenger, InitTargetRandState, ZoneRandState, Ledger, Vars) of
        {error, Reason}->
            lager:info("*** failed to find a target, reason ~p", [Reason]),
            noop;
        {ok, {TargetPubkeybin, TargetRandState}}->
            lager:info("*** found target ~p", [TargetPubkeybin]),
            {ok, LastChallenge} = blockchain_ledger_v1:current_height(Ledger),
            {ok, B} = blockchain:get_block(LastChallenge, Chain),
            Time = blockchain_block:time(B),
            %% TODO - need to handle older paths ?
            Path = blockchain_poc_path_v4:build(TargetPubkeybin, TargetRandState, Ledger, Time, Vars),
            lager:info("path created ~p", [Path]),
            N = erlang:length(Path),
            [<<IV:16/integer-unsigned-little, _/binary>> | LayerData] = blockchain_txn_poc_receipts_v1:create_secret_hash(
                Entropy,
                N + 1
            ),
            OnionList = lists:zip([libp2p_crypto:bin_to_pubkey(P) || P <- Path], LayerData),
            {Onion, Layers} = blockchain_poc_packet:build(Keys, IV, OnionList, BlockHash, Ledger),
            [_|LayerHashes] = [crypto:hash(sha256, L) || L <- Layers],
            Challengees = lists:zip(Path, LayerData),
            PacketHashes = lists:zip(Path, LayerHashes),
            Secret = libp2p_crypto:keys_to_bin(Keys),
            %% save the POC data to our local cache
            LocalPOC = #local_poc{
                onion_key_hash = OnionKeyHash,
                block_hash = BlockHash,
                target = TargetPubkeybin,
                onion = Onion,
                secret = Secret,
                challengees = Challengees,
                packet_hashes = PacketHashes,
                keys = Keys,
                start_height = POCStartHeight
            },
            ok = write_local_poc(LocalPOC, State),
            lager:info("starting poc for challengeraddr ~p, onionhash ~p", [Challenger, OnionKeyHash]),
            ok
    end.

-spec process_block_pocs(
    BlockHash :: blockchain_block:hash(),
    Block :: blockchain_block:block(),
    State :: state()
) -> ok.
process_block_pocs(
    BlockHash,
    Block,
    #state{chain = Chain} = State
) ->
    Ledger = blockchain:ledger(Chain),
    BlockHeight = blockchain_block:height(Block),
    %% get the empheral keys from the block
    %% these will be a prop with tuples as {MinerAddr, PocKeyHash}
    BlockPocEphemeralKeys = blockchain_block_v1:poc_keys(Block),
    BlockHeight = blockchain_block_v1:height(Block),
    [
        begin
            %% the published key is a hash of the public key, aka the onion key hash
            %% use this to check our local cache containing the secret keys of POCs owned by this validator
            %% if it is one of this local validators POCs, then kick it off
            %% public data on the POC is saved to the ledger whether its a local POC or not
            Ledger1 = blockchain_ledger_v1:new_context(Ledger),
            lager:info("saving public poc data for poc key ~p and challenger ~p", [OnionKeyHash, ChallengerAddr]),
            catch ok = blockchain_ledger_v1:save_public_poc(OnionKeyHash, ChallengerAddr, BlockHash, BlockHeight, Ledger1),
            ok = blockchain_ledger_v1:commit_context(Ledger1),

            case cached_poc_key(OnionKeyHash) of
                {ok, {_KeyHash, #poc_key_data{keys = Keys}}} ->
                    lager:info("found local poc key, starting a poc for ~p", [OnionKeyHash]),
                    %% its a locally owned POC key, so kick off a new POC
                    Vars = blockchain_utils:vars_binary_keys_to_atoms(maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))),
                    spawn_link(fun() -> initialize_poc(BlockHash, BlockHeight, Keys, Vars, State) end);
                _ ->
                    lager:info("failed to find local poc key for ~p", [OnionKeyHash]),
                    noop
            end
        end
        || {ChallengerAddr, OnionKeyHash} <- BlockPocEphemeralKeys
    ],
    ok.

-spec purge_local_pocs(
    Block :: blockchain_block:block(),
    State :: state()
) -> ok.
purge_local_pocs(
    Block,
    #state{chain = Chain, pub_key = SelfPubKeyBin, sig_fun = SigFun} = State
) ->
    BlockHeight = blockchain_block:height(Block),
    %% iterate over the active POCs, end and clean up any which have exceeded their life span
    LocalPOCs = local_pocs(State),
    lists:foreach(
        fun([#local_poc{start_height = POCStartHeight, onion_key_hash = OnionKeyHash} = POC]) ->
            case (BlockHeight - POCStartHeight) > ?POC_TIMEOUT of
                true ->
                    lager:info("*** purging local poc with key ~p", [OnionKeyHash]),
                    %% this POC's time is up, submit receipts we have received
                    ok = submit_receipts(POC, SelfPubKeyBin, SigFun, Chain);
                _ ->
                    lager:info("*** not purging local poc with key ~p.  BlockHeight: ~p, POCStartHeight: ~p", [OnionKeyHash, BlockHeight, POCStartHeight]),
                    ok
            end
        end,
        LocalPOCs
    ),
    ok.

-spec purge_public_pocs(
    Block :: blockchain_block:block(),
    Chain :: blockchain:blockchain()
) -> ok.
purge_public_pocs(
    Block,
    Chain
) ->
    Ledger = blockchain:ledger(Chain),
    BlockHeight = blockchain_block:height(Block),
    %% iterate over the public POCs, delete any which are beyond the lifespan of when the active POC would have ended
    PublicPOCs = blockchain_ledger_v1:active_public_pocs(Ledger),
    lists:foreach(
        fun(PublicPOC) ->
            POCHeight = blockchain_ledger_poc_v3:start_height(PublicPOC),
            OnionKeyHash = blockchain_ledger_poc_v3:onion_key_hash(PublicPOC),
            case (BlockHeight - POCHeight) > ?POC_TIMEOUT of
                true ->
                    %% the lifespan of any POC for this key has passed, we can GC
                    ok = blockchain_ledger_v1:delete_public_poc(OnionKeyHash, Ledger);
                _ ->
                    ok
            end
        end,
        PublicPOCs
    ),
    ok.

-spec purge_pocs_keys(
    Block :: blockchain_block:block()
) -> ok.
purge_pocs_keys(
    Block
) ->
    BlockHeight = blockchain_block:height(Block),
    %% iterate over the cached POC keys, delete any which are beyond the lifespan of when the active POC would have ended
    CachedPOCKeys = cached_poc_keys(),
    lists:foreach(
        fun({Key, #poc_key_data{receive_height = POCHeight}}) ->
            case (BlockHeight - POCHeight) > ?POC_TIMEOUT of
                true ->
                    %% the lifespan of any POC for this key has passed, we can GC
                    ok = delete_cached_poc_key(Key);
                _ ->
                    ok
            end
        end,
        CachedPOCKeys
    ),
    ok.

-spec submit_receipts(local_poc(), libp2p_crypto:pubkey_bin(), libp2p_crypto:sig_fun(), blockchain:blockchain()) -> ok.
submit_receipts(
    #local_poc{
        onion_key_hash = OnionKeyHash,
        responses = Responses0,
        secret = Secret,
        packet_hashes = LayerHashes,
        block_hash = BlockHash
    } = _Data,
    Challenger,
    SigFun,
    Chain
) ->
    Path1 = lists:foldl(
        fun({Challengee, LayerHash}, Acc) ->
            {Address, Receipt} = maps:get(Challengee, Responses0, {make_ref(), undefined}),
            %% get any witnesses not from the same p2p address and also ignore challengee as a witness (self-witness)
            Witnesses = [
                W
                || {A, W} <- maps:get(LayerHash, Responses0, []), A /= Address, A /= Challengee
            ],
            E = blockchain_poc_path_element_v1:new(Challengee, Receipt, Witnesses),
            [E | Acc]
        end,
        [],
        LayerHashes
    ),
    Txn0 =
        case blockchain:config(?poc_version, blockchain:ledger(Chain)) of
            {ok, PoCVersion} when PoCVersion >= 10 ->
                blockchain_txn_poc_receipts_v1:new(
                    Challenger,
                    Secret,
                    OnionKeyHash,
                    BlockHash,
                    lists:reverse(Path1)
                );
            _ ->
                %% hmm we shouldnt really hit here as this all started with poc version 10
                noop
        end,
    Txn1 = blockchain_txn:sign(Txn0, SigFun),
    lager:info("submitting blockchain_txn_poc_receipts_v1 for onion key hash ~p: ~p", [OnionKeyHash, Txn0]),
    ok = blockchain_worker:submit_txn(Txn1, fun(_Result) -> noop end),
%%    case miner_consensus_mgr:in_consensus() of
%%        false ->
%%            lager:info("node is not in consensus", []),
%%            ok = blockchain_worker:submit_txn(Txn1, fun(_Result) -> noop end);
%%        true ->
%%            lager:info("node is in consensus", []),
%%            ok = miner_hbbft_sidecar:submit(Txn1)
%%    end,

    ok.

-spec cache_poc_key(poc_key(), keys()) -> ok.
cache_poc_key(ID, Keys) ->
    true = ets:insert(?KEYS, {ID, Keys}).

-spec cached_poc_keys() -> [cached_poc_key_type()].
cached_poc_keys() ->
    ets:tab2list(?KEYS).

-spec delete_cached_poc_key(poc_key()) -> ok.
delete_cached_poc_key(Key) ->
    true = ets:delete(?KEYS, Key),
    ok.

-spec validate_witness(blockchain_poc_witness_v1:witness(), blockchain_ledger_v1:ledger()) ->
    boolean().
validate_witness(Witness, Ledger) ->
    Gateway = blockchain_poc_witness_v1:gateway(Witness),
    %% TODO this should be against the ledger at the time the receipt was mined
    case blockchain_ledger_v1:find_gateway_info(Gateway, Ledger) of
        {error, _Reason} ->
            lager:warning("failed to get witness ~p info ~p", [Gateway, _Reason]),
            false;
        {ok, GwInfo} ->
            case blockchain_ledger_gateway_v2:location(GwInfo) of
                undefined ->
                    lager:warning("ignoring witness ~p location undefined", [Gateway]),
                    false;
                _ ->
                    blockchain_poc_witness_v1:is_valid(Witness, Ledger)
            end
    end.

check_addr_hash(_PeerAddr, #state{addr_hash_filter = undefined}) ->
    undefined;
check_addr_hash(PeerAddr, #state{
    addr_hash_filter = #addr_hash_filter{byte_size = Size, salt = Hash, bloom = Bloom}
}) ->
    case multiaddr:protocols(PeerAddr) of
        [{"ip4", Address}, {_, _}] ->
            {ok, Addr} = inet:parse_ipv4_address(Address),
            Val = binary:part(
                enacl:pwhash(
                    list_to_binary(tuple_to_list(Addr)),
                    binary:part(Hash, {0, enacl:pwhash_SALTBYTES()})
                ),
                {0, Size}
            ),
            case bloom:check_and_set(Bloom, Val) of
                true ->
                    true;
                false ->
                    Val
            end;
        _ ->
            undefined
    end.

-spec maybe_init_addr_hash(#state{}) -> #state{}.
maybe_init_addr_hash(#state{chain = undefined} = State) ->
    %% no chain
    State;
maybe_init_addr_hash(#state{chain = Chain, addr_hash_filter = undefined} = State) ->
    %% check if we have the block we need
    Ledger = blockchain:ledger(Chain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, Height} = blockchain:height(Chain),
                    StartHeight = max(Height - (Height rem Interval), 1),
                    %% check if we have this block
                    case blockchain:get_block(StartHeight, Chain) of
                        {ok, Block} ->
                            Hash = blockchain_block:hash_block(Block),
                            %% ok, now we can build the filter
                            Gateways = blockchain_ledger_v1:gateway_count(Ledger),
                            {ok, Bloom} = bloom:new_optimal(Gateways, ?ADDR_HASH_FP_RATE),
                            sync_filter(Block, Bloom, Chain),
                            State#state{
                                addr_hash_filter = #addr_hash_filter{
                                    start = StartHeight,
                                    height = Height,
                                    byte_size = Bytes,
                                    salt = Hash,
                                    bloom = Bloom
                                }
                            };
                        _ ->
                            State
                    end;
                _ ->
                    State
            end;
        _ ->
            State
    end;
maybe_init_addr_hash(
    #state{
        chain = Chain,
        addr_hash_filter = #addr_hash_filter{
            start = StartHeight,
            height = Height,
            byte_size = Bytes,
            salt = Hash,
            bloom = Bloom
        }
    } = State
) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain:config(?poc_addr_hash_byte_count, Ledger) of
        {ok, Bytes} when is_integer(Bytes), Bytes > 0 ->
            case blockchain:config(?poc_challenge_interval, Ledger) of
                {ok, Interval} ->
                    {ok, CurHeight} = blockchain:height(Chain),
                    case max(Height - (Height rem Interval), 1) of
                        StartHeight ->
                            case CurHeight of
                                Height ->
                                    %% ok, everything lines up
                                    State;
                                _ ->
                                    case blockchain:get_block(Height + 1, Chain) of
                                        {ok, Block} ->
                                            sync_filter(Block, Bloom, Chain),
                                            State#state{
                                                addr_hash_filter = #addr_hash_filter{
                                                    start = StartHeight,
                                                    height = CurHeight,
                                                    byte_size = Bytes,
                                                    salt = Hash,
                                                    bloom = Bloom
                                                }
                                            };
                                        _ ->
                                            State
                                    end
                            end;
                        _NewStart ->
                            %% filter is stale
                            maybe_init_addr_hash(State#state{addr_hash_filter = undefined})
                    end;
                _ ->
                    State
            end;
        _ ->
            State#state{addr_hash_filter = undefined}
    end.

sync_filter(StopBlock, Bloom, Blockchain) ->
    blockchain:fold_chain(
        fun(Blk, _) ->
            blockchain_utils:find_txn(Blk, fun(T) ->
                case blockchain_txn:type(T) == blockchain_txn_poc_receipts_v1 of
                    true ->
                        %% abuse side effects here for PERFORMANCE
                        [update_addr_hash(Bloom, E) || E <- blockchain_txn_poc_receipts_v1:path(T)];
                    false ->
                        ok
                end,
                false
            end),
            case Blk == StopBlock of
                true ->
                    return;
                false ->
                    continue
            end
        end,
        any,
        element(2, blockchain:head_block(Blockchain)),
        Blockchain
    ).

-spec update_addr_hash(
    Bloom :: bloom_nif:bloom(),
    Element :: blockchain_poc_path_element_v1:poc_element()
) -> ok.
update_addr_hash(Bloom, Element) ->
    case blockchain_poc_path_element_v1:receipt(Element) of
        undefined ->
            ok;
        Receipt ->
            case blockchain_poc_receipt_v1:addr_hash(Receipt) of
                undefined ->
                    ok;
                Hash ->
                    bloom:set(Bloom, Hash)
            end
    end.

%% ------------------------------------------------------------------
%% DB functions
%% ------------------------------------------------------------------
-spec get_local_poc(OnionKeyHash :: binary(),
                    State :: state()) ->
    {ok, local_poc()} | {error, any()}.
get_local_poc(OnionKeyHash, #state{db=DB, cf=CF}) ->
    case rocksdb:get(DB, CF, OnionKeyHash, []) of
        {ok, Bin} ->
            [POC] = erlang:binary_to_term(Bin),
            {ok, POC};
        not_found ->
            {error, not_found};
        Error ->
            lager:error("error: ~p", [Error]),
            Error
    end.

%%-spec append_local_poc(NewLocalPOC :: local_poc(),
%%                       State :: state()) -> ok | {error, any()}.
%%append_local_poc(#local_poc{onion_key_hash=OnionKeyHash} = NewLocalPOC, #state{db=DB, cf=CF}=State) ->
%%    case get_local_poc(OnionKeyHash, State) of
%%        {ok, SavedLocalPOCs} ->
%%            %% check we're not writing something we already have
%%            case lists:member(NewLocalPOC, SavedLocalPOCs) of
%%                true ->
%%                    ok;
%%                false ->
%%                    ToInsert = erlang:term_to_binary([NewLocalPOC | SavedLocalPOCs]),
%%                    rocksdb:put(DB, CF, OnionKeyHash, ToInsert, [])
%%            end;
%%        {error, not_found} ->
%%            ToInsert = erlang:term_to_binary([NewLocalPOC]),
%%            rocksdb:put(DB, CF, OnionKeyHash, ToInsert, []);
%%        {error, _}=E ->
%%            E
%%    end.

local_pocs(#state{db=DB, cf=CF}) ->
    {ok, Itr} = rocksdb:iterator(DB, CF, []),
    local_pocs(Itr, rocksdb:iterator_move(Itr, first), []).

local_pocs(Itr, {error, invalid_iterator}, Acc) ->
    catch rocksdb:iterator_close(Itr),
    Acc;
local_pocs(Itr, {ok, _, LocalPOCBin}, Acc) ->
    local_pocs(Itr, rocksdb:iterator_move(Itr, next), [binary_to_term(LocalPOCBin)|Acc]).

%%-spec overwrite_local_poc(LocalPOC :: local_poc(),
%%                          State :: state()) -> ok | {error, any()}.
%%overwrite_local_poc(#local_poc{onion_key_hash = OnionKeyHash} = LocalPOC, State) ->
%%    case get_local_poc(OnionKeyHash, State) of
%%        {error, _} ->
%%            write_local_poc(LocalPOC, State);
%%        {ok, [KnownLocalPOC]} ->
%%            case blockchain_state_channel_v1:is_causally_newer(SC, KnownSC) of
%%                true -> write_sc(SC, State);
%%                false -> ok
%%            end
%%    end.

-spec write_local_poc(  LocalPOC ::local_poc(),
                        State :: state()) -> ok.
write_local_poc(#local_poc{onion_key_hash=OnionKeyHash} = LocalPOC, #state{db=DB, cf=CF}) ->
    ToInsert = erlang:term_to_binary([LocalPOC]),
    rocksdb:put(DB, CF, OnionKeyHash, ToInsert, []).
