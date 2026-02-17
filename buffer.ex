defmodule Raft do
  @moduledoc """
  An implementation of the Raft consensus protocol.
  """
  # Shouldn't need to spawn anything from this module, but if you do
  # you should add spawn to the imports.
  import Emulation, only: [send: 2, timer: 1, now: 0, whoami: 0]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  require Fuzzers
  # This allows you to use Elixir's loggers
  # for messages. See
  # https://timber.io/blog/the-ultimate-guide-to-logging-in-elixir/
  # if you are interested in this. Note we currently purge all logs
  # below Info
  require Logger

  # This structure contains all the process state
  # required by the Raft protocol.
  defstruct(
    # The list of current proceses.
    view: nil,
    # Current leader.
    current_leader: nil,
    # Time before starting an election.
    min_election_timeout: nil,
    max_election_timeout: nil,
    election_timer: nil,
    # Time between heartbeats from the leader.
    heartbeat_timeout: nil,
    heartbeat_timer: nil,
    # Persistent state on all servers.
    current_term: nil,
    voted_for: nil,
    # A short note on log structure: The functions that follow
    # (e.g., get_last_log_index, commit_log_index, etc.) all
    # assume that the log is a list with later entries (i.e.,
    # entries with higher index numbers) appearing closer to
    # the head of the list, and that index numbers start with 1.
    # For example if the log contains 3 entries committe in term
    # 2, 2, and 1 we would expect:
    #
    # `[{index: 3, term: 2, ..}, {index: 2, term: 2, ..},
    #     {index: 1, term: 1}]`
    #
    # If you change this structure, you will need to change
    # those functions.
    #
    # Finally, it might help to know that two lists can be
    # concatenated using `l1 ++ l2`
    log: nil,
    # Volatile state on all servers
    commit_index: nil,
    last_applied: nil,
    # Volatile state on leader
    is_leader: nil,
    next_index: nil,
    match_index: nil,
    # The queue we are building using this RSM.
    queue: nil
  )

  @doc """
  Create state for an initial Raft cluster. Each
  process should get an appropriately updated version
  of this state.
  """
  @spec new_configuration(
          [atom()],
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: %Raft{}
  def new_configuration(
        view,
        leader,
        min_election_timeout,
        max_election_timeout,
        heartbeat_timeout
      ) do
    %Raft{
      view: view,
      current_leader: leader,
      min_election_timeout: min_election_timeout,
      max_election_timeout: max_election_timeout,
      heartbeat_timeout: heartbeat_timeout,
      # Start from term 1
      current_term: 1,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      is_leader: false,
      next_index: nil,
      match_index: nil,
      queue: :queue.new()
    }
  end

  # Enqueue an item, this **modifies** the state
  # machine, and should only be called when a log
  # entry is committed.
  @spec enqueue(%Raft{}, any()) :: %Raft{}
  defp enqueue(state, item) do
    %{state | queue: :queue.in(item, state.queue)}
  end

  # Dequeue an item, modifying the state machine.
  # This function should only be called once a
  # log entry has been committed.
  @spec dequeue(%Raft{}) :: {:empty | {:value, any()}, %Raft{}}
  defp dequeue(state) do
    {ret, queue} = :queue.out(state.queue)
    {ret, %{state | queue: queue}}
  end

  @doc """
  Commit a log entry, advancing the state machine. This
  function returns a tuple:
  * The first element is {requester, return value}. Your
    implementation should ensure that the leader who committed
    the log entry sends the return value to the requester.
  * The second element is the updated state.
  """
  @spec commit_log_entry(%Raft{}, %Raft.LogEntry{}) ::
          {{atom() | pid(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_entry(state, entry) do
    case entry do
      %Raft.LogEntry{operation: :nop, requester: r, index: i} ->
        {{r, :ok}, %{state | commit_index: i}}

      %Raft.LogEntry{operation: :enq, requester: r, argument: e, index: i} ->
        {{r, :ok}, %{enqueue(state, e) | commit_index: i}}

      %Raft.LogEntry{operation: :deq, requester: r, index: i} ->
        {ret, state} = dequeue(state)
        {{r, ret}, %{state | commit_index: i}}

      %Raft.LogEntry{} ->
        raise "Log entry with an unknown operation: maybe an empty entry?"

      _ ->
        raise "Attempted to commit something that is not a log entry."
    end
  end

  @doc """
  Commit log at index `index`. This index, which one should read from
  the log entry is assumed to start at 1. This function **does not**
  ensure that commits are processed in order.
  """
  @spec commit_log_index(%Raft{}, non_neg_integer()) ::
          {:noentry | {atom(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_index(state, index) do
    if length(state.log) < index do
      {:noentry, state}
    else
      # Note that entry indexes are all 1, which in
      # turn means that we expect commit indexes to
      # be 1 indexed. Now a list is a reversed log,
      # so what we can do here is simple: 
      # Given 0-indexed index i, length(log) - 1 - i
      # is the ith list element. => length(log) - (i +1),
      # and hence length(log) - index is what we want.
      correct_idx = length(state.log) - index
      commit_log_entry(state, Enum.at(state.log, correct_idx))
    end
  end

  # The next few functions are public so we can test them, see
  # log_test.exs.
  @doc """
  Get index for the last log entry.
  """
  @spec get_last_log_index(%Raft{}) :: non_neg_integer()
  def get_last_log_index(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).index
  end

  @doc """
  Get term for the last log entry.
  """
  @spec get_last_log_term(%Raft{}) :: non_neg_integer()
  def get_last_log_term(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).term
  end

  @doc """
  Check if log entry at index exists.
  """
  @spec logged?(%Raft{}, non_neg_integer()) :: boolean()
  def logged?(state, index) do
    index > 0 && length(state.log) >= index
  end

  @doc """
  Get log entry at `index`.
  """
  @spec get_log_entry(%Raft{}, non_neg_integer()) ::
          :noentry | %Raft.LogEntry{}
  def get_log_entry(state, index) do
    if index <= 0 || length(state.log) < index do
      :noentry
    else
      # Note that entry indexes are all 1, which in
      # turn means that we expect commit indexes to
      # be 1 indexed. Now a list is a reversed log,
      # so what we can do here is simple:
      # Given 0-indexed index i, length(log) - 1 - i
      # is the ith list element. => length(log) - (i +1),
      # and hence length(log) - index is what we want.
      correct_idx = length(state.log) - index
      Enum.at(state.log, correct_idx)
    end
  end

  @doc """
  Get log entries starting at index.
  """
  @spec get_log_suffix(%Raft{}, non_neg_integer()) :: [%Raft.LogEntry{}]
  def get_log_suffix(state, index) do
    if length(state.log) < index do
      []
    else
      correct_idx = length(state.log) - index
      Enum.take(state.log, correct_idx + 1)
    end
  end

  @doc """
  Truncate log entry at `index`. This removes log entry
  with index `index` and larger.
  """
  @spec truncate_log_at_index(%Raft{}, non_neg_integer()) :: %Raft{}
  def truncate_log_at_index(state, index) do
    if length(state.log) < index do
      # Nothing to do
      state
    else
      to_drop = length(state.log) - index + 1
      %{state | log: Enum.drop(state.log, to_drop)}
    end
  end

  @doc """
  Add log entries to the log. This adds entries to the beginning
  of the log, we assume that entries are already correctly ordered
  (see structural note about log above.).
  """
  @spec add_log_entries(%Raft{}, [%Raft.LogEntry{}]) :: %Raft{}
  def add_log_entries(state, entries) do
    %{state | log: entries ++ state.log}
  end

  @doc """
  make_leader changes process state for a process that
  has just been elected leader.
  """
  @spec make_leader(%Raft{}) :: %Raft{
          is_leader: true,
          next_index: map(),
          match_index: map()
        }
  def make_leader(state) do
    log_index = get_last_log_index(state)

    # next_index needs to be reinitialized after each
    # election.
    next_index =
      state.view
      |> Enum.map(fn v -> {v, log_index} end)
      |> Map.new()

    # match_index needs to be reinitialized after each
    # election.
    match_index =
      state.view
      |> Enum.map(fn v -> {v, 0} end)
      |> Map.new()

    %{
      state
      | is_leader: true,
        next_index: next_index,
        match_index: match_index,
        current_leader: whoami()
    }
  end

  @doc """
  make_follower changes process state for a process
  to mark it as a follower.
  """
  @spec make_follower(%Raft{}) :: %Raft{
          is_leader: false
        }
  def make_follower(state) do
    %{state | is_leader: false}
  end

  # update_leader: update the process state with the
  # current leader.
  @spec update_leader(%Raft{}, atom()) :: %Raft{current_leader: atom()}
  defp update_leader(state, who) do
    %{state | current_leader: who}
  end

  # Compute a random election timeout between
  # state.min_election_timeout and state.max_election_timeout.
  # See the paper to understand the reasoning behind having
  # a randomized election timeout.
  @spec get_election_time(%Raft{}) :: non_neg_integer()
  defp get_election_time(state) do
    state.min_election_timeout +
      :rand.uniform(
        state.max_election_timeout -
          state.min_election_timeout
      )
  end

  # Save a handle to the election timer.
  @spec save_election_timer(%Raft{}, reference()) :: %Raft{}
  defp save_election_timer(state, timer) do
    %{state | election_timer: timer}
  end

  # Save a handle to the hearbeat timer.
  @spec save_heartbeat_timer(%Raft{}, reference()) :: %Raft{}
  defp save_heartbeat_timer(state, timer) do
    %{state | heartbeat_timer: timer}
  end

  # Utility function to send a message to all
  # processes other than the caller. Should only be used by leader.
  @spec broadcast_to_others(%Raft{is_leader: true}, any()) :: [boolean()]
  defp broadcast_to_others(state, message) do
    me = whoami()

    state.view
    |> Enum.filter(fn pid -> pid != me end)
    |> Enum.map(fn pid -> send(pid, message) end)
  end

  # END OF UTILITY FUNCTIONS. You should not need to (but are allowed to)
  # change any of the code above this line, but will definitely need to
  # change the code that follows.

  # This function should cancel the current
  # election timer, and set  a new one. You can use
  # `get_election_time` defined above to get a
  # randomized election timeout. You might need
  # to call this function from within your code.
  @spec reset_election_timer(%Raft{}) :: %Raft{}
  defp reset_election_timer(state) do
    # TODO: Set a new election timer
    # You might find `save_election_timer` of use.
    new_election_time=get_election_time(state)
    if is_nil(state.election_timer) do
      new_timer=Emulation.timer(new_election_time,:election_time_up)
      save_election_timer(state,new_timer)
    else
      Emulation.cancel_timer(state.election_timer)
      new_timer=Emulation.timer(new_election_time,:election_time_up)
      save_election_timer(state,new_timer)
    end
    # raise "Not yet implemented"
  end

  # This function should cancel the current
  # hearbeat timer, and set  a new one. You can
  # get heartbeat timeout from `state.heartbeat_timeout`.
  # You might need to call this from your code.
  @spec reset_heartbeat_timer(%Raft{}) :: %Raft{}
  defp reset_heartbeat_timer(state) do
    # TODO: Set a new heartbeat timer.
    # You might find `save_heartbeat_timer` of use.
    if is_nil(state.heartbeat_timer) do
      new_heartbeat_timer=Emulation.timer(state.heartbeat_timeout,:heartbeat_time_up)
      save_heartbeat_timer(state,new_heartbeat_timer)
    else
      Emulation.cancel_timer(state.heartbeat_timer)
      new_heartbeat_timer=Emulation.timer(state.heartbeat_timeout,:heartbeat_time_up)
      save_heartbeat_timer(state,new_heartbeat_timer)
    end
    # raise "Not yet implemented"
  end

  @doc """
  This function transitions a process so it is
  a follower.
  """
  @spec become_follower(%Raft{}) :: no_return()
  def become_follower(state) do
    # TODO: Do anything you need to when a process
    # transitions to a follower.

    # Just call make follower, maybe reset timers?
    # This function probably gets called in leader and candidate
    # update leader gets called based on RPC requests, where a potential leader sends its appendEnrty after it establishes majority
    # through heartbeats
    # raise "Not yet implemented."
    IO.puts("#{whoami()} became follower")
    state=reset_election_timer(state) #doubtful about this tho
    # state=reset_heartbeat_timer(state)
    n_state=make_follower(state)
    follower(n_state, nil)
  end

  @doc """
  This function implements the state machine for a process
  that is currently a follower.

  `extra_state` can be used to hod anything that you find convenient
  when building your implementation.
  """
  @spec follower(%Raft{is_leader: false}, any()) :: no_return()
  def follower(state, extra_state) do
    receive do
      :election_time_up ->
        # call become candidate
        IO.puts("follower #{whoami()} election time is up")
        become_candidate(state)
      # :heartbeat_time_up ->
      #   #call become candidate
      #   IO.puts("follower #{whoami()} heartbeat time is up")
      #   become_candidate(state)
      # Messages that are a part of Raft.
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest received by a
        # follower
        IO.puts(
          "#{whoami()} follower Received append entry for term #{term} with leader #{leader_id} " <>
            "(#{leader_commit_index})"
        )
        # IO.puts(
        #   "prev log index #{prev_log_index} prev log term: #{prev_log_term}"
        # )
        # if entries==nil do
        #   IO.puts("enrties: nil")
        # else
        #   IO.puts("enrties: #{length(entries)}")
        # end
        
        # do something about initial state when index=0

        # reset heartbeat timers
        # if entries==[] do
        #   n_state=reset_election_timer(state)
        #   n_state=update_leader(n_state,leader_id)
        #   follower(n_state,extra_state)
        # end
        state=reset_election_timer(state)
        cond do
          term<state.current_term ->
            rpc_response=Raft.AppendEntryResponse.new(state.current_term,nil,false) #persistent current term is greater so heartbeat is from a false leader, maybe make the leader a follower in response
            send(sender,rpc_response)
            # IO.puts("case 1")
            follower(state,extra_state)
          entries==[] ->
            n_state=reset_election_timer(state)
            n_state=update_leader(n_state,leader_id)
            follower(n_state,extra_state)
          (prev_log_index != 0) and (logged?(state,prev_log_index) == false)->
            rpc_response=Raft.AppendEntryResponse.new(state.current_term,get_last_log_index(state),false)
            send(sender,rpc_response)
            # IO.puts("case 2")
            follower(state,extra_state)
          (prev_log_index != 0) and (prev_log_term != get_log_entry(state,prev_log_index).term)->
            # delete existing log entry and all that followit
            # send false but include last log term and last log index
            state=truncate_log_at_index(state,prev_log_index)
            rpc_response=Raft.AppendEntryResponse.new(state.current_term,get_last_log_index(state),false)
            send(sender,rpc_response)
            # IO.puts("case 3")
            follower(state,extra_state)
          (prev_log_index == 0) or (prev_log_term == get_log_entry(state,prev_log_index).term)->
            # best case scenario -> add log entries
            state = 
              if entries != [] do
                n_state=add_log_entries(state,entries)
                # IO.puts("adding entries to follower")
                # IO.inspect(entries)
                # IO.inspect(state)
                n_state
              else
                state
              end

            # check leader commit index and update commit index
            state = 
              if leader_commit_index>state.commit_index do
                new_commit_index=min(leader_commit_index,get_last_log_index(state))
                n_state=%{state | commit_index: new_commit_index}
                n_state
              else
                state
              end

            # commit entries to state machine
            lapplied_val=state.last_applied
            {_,state}=
            Enum.reduce_while(state.last_applied..state.commit_index-1//1, {lapplied_val,state}, fn current, _ ->
              if current < state.commit_index do
                # IO.puts("Applying log entry #{current + 1}")
                state=%{state | last_applied: current + 1}
                {{_requester,_ret_val},n_state}=commit_log_index(state,state.last_applied)
                {:cont, {current + 1,n_state}}
              else
                {:halt, {current,state}}
              end
            end)
            # check this?
            # IO.inspect(state)
            state=%{state | current_term: term}
            state=update_leader(state,leader_id)
            rpc_response=Raft.AppendEntryResponse.new(state.current_term,get_last_log_index(state),true)

            send(sender,rpc_response)
            # IO.puts("case 4")
            follower(state,extra_state)
        end
        # raise "Not yet implemented"

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an AppendEntryResponse received by
        # a follower.
        # just have a warning since this behaviour isnt expected. Ideally a follower should never get this response
        IO.puts(
          "#{whoami()} Follower received append entry response #{term}," <>
            " index #{index}, succcess #{inspect(succ)}"
        )
        # IO.warn(
        #   "Follower received append entry response #{term}," <>
        #     " index #{index}, succcess #{inspect(succ)} -> this is not correct behaviour"
        # )
        follower(state,extra_state)
        # raise "Not yet implemented"

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote call received by a
        # follower.
        IO.puts(
          "#{whoami()} Follower received RequestVote " <>
            "term = #{term}, candidate = #{candidate} "
        )
        # first check if term is greater than follower's term -> false  
        # then check logs -> if last term of follower is > last log term of candidate -> false
        # if they are same then if last log index of follower > last log index of candidate -> false
        # everything good -> change current term, update votedFor and return response

        state=
        if term>state.current_term do
          state= %{state | voted_for: nil}
          state=%{state | current_term: term}
          state=
          if last_log_term > get_last_log_term(state) do
            rpc_response=Raft.RequestVoteResponse.new(state.current_term,true)
            state=%{state | voted_for: candidate}
            send(sender,rpc_response)
            state
          else
            state=
            if last_log_term == get_last_log_term(state) do
              {state,rpc_response} = 
                if last_log_index >= get_last_log_index(state) do
                  n_state=%{state | voted_for: candidate}
                  {n_state,Raft.RequestVoteResponse.new(state.current_term,true)}
                else
                  {state,Raft.RequestVoteResponse.new(state.current_term,false)}
                end
              send(sender,rpc_response)
              state
            else
              rpc_response=Raft.RequestVoteResponse.new(state.current_term,false)
              send(sender, rpc_response)
              state
            end
            state
          end
          state
        else
          state=
          if ((term==state.current_term) and (state.voted_for==candidate)) do
            rpc_response=Raft.RequestVoteResponse.new(state.current_term,true)
            send(sender, rpc_response)
            state
          else
            rpc_response=Raft.RequestVoteResponse.new(state.current_term,false)
            send(sender,rpc_response)
            state
          end
          state
        end
        follower(state,extra_state) 

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle a RequestVoteResponse.
        IO.puts(
          "#{whoami()} Follower received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        # IO.warn(
        #   "Follower received RequestVoteResponse " <>
        #     "term = #{term}, granted = #{inspect(granted)} -> this is not correct behaviour"
        # )
        follower(state,extra_state)
        # raise "Not yet implemented"

      # Messages from external clients. In each case we
      # tell the client that it should go talk to the
      # leader.
      {sender, :nop} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, {:enq, item}} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, :deq} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        follower(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        follower(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {state.current_leader, state.current_term})
        follower(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :follower)
        follower(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        follower(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        follower(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end

  @doc """
  This function transitions a process that is not currently
  the leader so it is a leader.
  """
  @spec become_leader(%Raft{is_leader: false}) :: no_return()
  def become_leader(state) do
    # TODO: Send out any one time messages that need to be sent,
    # you might need to update the call to leader too.
    # raise "Not yet implemented"
    IO.puts("#{whoami()} became leader")
    new_leader=make_leader(state)
    # new_leader=%{new_leader | current_term: state.current_term+1}
    # new_leader=reset_election_timer(new_leader)
    new_leader=reset_heartbeat_timer(new_leader)
    heartbeat_request=Raft.AppendEntryRequest.new(new_leader.current_term,new_leader.current_leader,get_last_log_index(new_leader), get_last_log_term(new_leader),[],new_leader.commit_index)
    broadcast_to_others(new_leader,heartbeat_request)
    # broadcast intitial append entry RPCs to everyone
    # use an extra state to keep track of append entry responses??
    # tracking_state=%{heartbeat_request: 1}
    
    
    leader(new_leader, nil)
  end

  @doc """
  This function implements the state machine for a process
  that is currently the leader.

  `extra_state` can be used to hold any additional information.
  HINT: It might be useful to track the number of responses
  received for each AppendEntry request.
  """
  @spec leader(%Raft{is_leader: true}, any()) :: no_return()
  def leader(state, extra_state) do
    # check indexes to establish quorum and increment last_applied
    state=
    if state.is_leader==true do
      min_mvalue = Enum.min(Map.values(state.match_index))
      max_mvalue = Enum.max(Map.values(state.match_index))
      total_processes=length(state.view)
      start_val=min_mvalue
      # update commit index based on quorum
      {_,state} =
      Enum.reduce_while(min_mvalue..max_mvalue//1, {start_val,state}, fn current, _ ->
        if start_val <= max_mvalue do
          # IO.puts("count of index #{current}")
          count = Enum.count(state.match_index, fn {_key, value} -> ((value >= current) and ((get_log_entry(state,value)!=(:noentry)) and (get_log_entry(state,value).term==state.current_term))) end)
          new_state=
            if count > total_processes/2 do
              %{state | commit_index: current}
            else
              state
            end
            {:cont, {current + 1,new_state}}
        else 
          {:halt, {current,state}}
        end
      end)

      # apply to state machine and update last applied
      lapplied_val=state.last_applied
      {_,state}=
      Enum.reduce_while(state.last_applied..state.commit_index-1//1, {lapplied_val,state}, fn current, _ ->
        if current < state.commit_index do
          # IO.puts("Applying log entry #{current + 1}")
          state=%{state | last_applied: current + 1}
          {{requester,ret_val},n_state}=commit_log_index(state,state.last_applied)
          # send response to client
          send(requester,ret_val)
          {:cont, {current + 1,n_state}}
        else
          {:halt, {current,state}}
        end
      end)
      state
    else
      state
    end

    receive do
      # :election_time_up ->
      #   # call become candidate
      #   IO.puts("#{whoami()} election time up")
      #   # IO.puts(whoami())
      #   become_candidate(state)
      :heartbeat_time_up ->
        IO.puts("heartbeat time up")
        state=reset_heartbeat_timer(state)
        heartbeat_request=Raft.AppendEntryRequest.new(state.current_term,state.current_leader,get_last_log_index(state), get_last_log_term(state),[],state.commit_index)
        broadcast_to_others(state,heartbeat_request)
        leader(state,extra_state)
      
      # Messages that are a part of Raft.
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest seen by the leader.
        IO.puts(
          "#{whoami()} Leader Received append entry for term #{term} with leader #{
            leader_id
          } " <>
            "(#{leader_commit_index})"
        )
        # IO.warn(
        #   "Leader Received append entry for term #{term} with leader #{
        #     leader_id
        #   } " <>
        #     "(#{leader_commit_index}) -> this is not correct behaviour"
        # )
        # raise "Not yet implemented"
        if term>state.current_term do
          state=%{state | current_term: term}
          state=%{state | voted_for: nil}
          state=update_leader(state,leader_id)
          become_follower(state)
        else
          leader(state,extra_state)
        end

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an AppendEntryResposne received by the leader.
        IO.puts(
          "#{whoami()} Leader Received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )

        cond do
          (term>state.current_term) ->
            # leader isn't leader. 
            IO.warn("leader is not the correct leader")
            # make follower
            state=%{state | current_term: term}
            become_follower(state)
            # leader(state, extra_state)
          (succ==false) ->
            # change index and resend requests
            # IO.puts("false response #{term} #{index}")
            nind=state.next_index
            nind=Map.put(nind,sender,nind[sender]-1)
            # nind=%{nind | sender: index+1}
            state=%{state | next_index: nind}
            # state.next_index=%{state.next_index | sender: index+1}
            # prev_index=state.next_index[sender]-
            # prev_term=
            # if (get_log_entry(state,prev_index)!=(:noentry)) do
            #   get_log_entry(state,prev_index).term
            # else
            #   0
            # end
            prev_index=state.next_index[sender]
            prev_term=
            if (get_log_entry(state,index)!=(:noentry)) do
              get_log_entry(state,index).term
            else
              state.current_term
            end

            entries_to_send=get_log_suffix(state,index+1)
            resend_request=Raft.AppendEntryRequest.new(state.current_term,state.current_leader,prev_index,prev_term,entries_to_send,state.commit_index)
            send(sender,resend_request)
            leader(state, extra_state)
          (succ==true) ->
            # again update indexes but do not resend
            # IO.puts("true response #{term} #{index}")
            nind=state.next_index
            nind=Map.put(nind,sender,nind[sender]+1)
            # nind=%{nind | :sender: nind[sender]+1}
            state=%{state | next_index: nind}
            # state.next_index = %{state.next_index | sender: state.next_index[sender]+1} #check this
            mind=state.match_index
            mind=Map.put(mind,sender,index)
            # mind=%{mind | sender: index}
            state=%{state | match_index: mind}
            # state.match_index = %{state.match_index | sender: index} #check this
            leader(state, extra_state)
        end
        # handle everything
        # raise "Not yet implemented"

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote call at the leader.
        IO.puts(
          "#{whoami()} Leader received RequestVote " <>
            "term = #{term}, candidate = #{candidate} "
        )

        if term>state.current_term do
          state = %{state | voted_for: nil}
          state = %{state | current_term: term}
          state=
          if last_log_term > get_last_log_term(state) do
            rpc_response=Raft.RequestVoteResponse.new(state.current_term,true)
            state=%{state | voted_for: candidate}
            send(sender,rpc_response)
            state
          else
            state=
            if last_log_term == get_last_log_term(state) do
              {state,rpc_response} = 
                if last_log_index >= get_last_log_index(state) do
                  n_state=%{state | voted_for: candidate}
                  {n_state,Raft.RequestVoteResponse.new(state.current_term,true)}
                else
                  {state,Raft.RequestVoteResponse.new(state.current_term,false)}
                end
              send(sender,rpc_response)
              state
            else
              rpc_response=Raft.RequestVoteResponse.new(state.current_term,false)
              send(sender, rpc_response)
              state
            end
          end
          become_follower(state)
        end
        leader(state,extra_state) 


      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle RequestVoteResponse at a leader.         
        IO.puts(
          "#{whoami()} Leader received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        # IO.warn(
        #   "Leader received RequestVoteResponse " <>
        #     "term = #{term}, granted = #{inspect(granted)} -> not really supposed to happen"
        # )

        if term > state.current_term do 
          state = %{state | voted_for: nil}
          state = %{state | current_term: term}
          become_follower(state)
        else
          leader(state, extra_state)
        end
        # leader(state,extra_state)
        # raise "Not yet implemented"

      # Messages from external clients. For all of what follows
      # you should send the `sender` an :ok (see `Raft.Client`
      # below) only after the request has completed, i.e., after
      # the log entry corresponding to the request has been **committed**.
      {sender, :nop} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.nop(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )
        prev_index=get_last_log_index(state)
        prev_term=get_last_log_term(state)
        state=add_log_entries(state,[entry])
        entries_to_send=get_log_suffix(state,prev_index+1)
        req=Raft.AppendEntryRequest.new(state.current_term,state.current_leader,prev_index,prev_term,entries_to_send,state.commit_index)
        broadcast_to_others(state,req)
        # IO.puts("sent nop")
        # for each follower send RPCs
        # TODO: You might need to update the following call.
        leader(state, extra_state)

      {sender, {:enq, item}} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.enqueue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender,
            item
          )
        prev_index=get_last_log_index(state)
        prev_term=get_last_log_term(state)
        state=add_log_entries(state,[entry])
        entries_to_send=get_log_suffix(state,prev_index+1)
        req=Raft.AppendEntryRequest.new(state.current_term,state.current_leader,prev_index,prev_term,entries_to_send,state.commit_index)
        broadcast_to_others(state,req)
        # IO.puts("sent enq")

        # TODO: You might need to update the following call.
        leader(state, extra_state)

      {sender, :deq} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.dequeue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )
        prev_index=get_last_log_index(state)
        prev_term=get_last_log_term(state)
        state=add_log_entries(state,[entry])
        entries_to_send=get_log_suffix(state,prev_index+1)
        req=Raft.AppendEntryRequest.new(state.current_term,state.current_leader,prev_index,prev_term,entries_to_send,state.commit_index)
        broadcast_to_others(state,req)
        # IO.puts("sent deq")

        # TODO: You might need to update the following call.
        leader(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        leader(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        leader(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {whoami(), state.current_term})
        leader(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :leader)
        leader(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        send(sender, :ok)

        leader(
          %{state | min_election_timeout: min, max_election_timeout: max},
          extra_state
        )

      {sender, {:set_heartbeat_timeout, timeout}} ->
        state = %{state | heartbeat_timeout: timeout}
        state = reset_heartbeat_timer(state)
        send(sender, :ok)
        leader(state, extra_state)
    end
  end

  @doc """
  This function transitions a process to candidate.
  """
  @spec become_candidate(%Raft{is_leader: false}) :: no_return()
  def become_candidate(state) do
    # TODO:   Send out any messages that need to be sent out
    # you might need to update the call to candidate below.
    # raise "Not yet implemented"
    # incerement current term
    # vote for self
    # reset timers
    # broadcast rpc's requesting votes
    IO.puts("#{whoami()} became candidate")
    state=%{state | is_leader: false}
    state=%{state | current_term: state.current_term+1}
    state=%{state | voted_for: whoami()}
    state=reset_election_timer(state)
    #state=reset_heartbeat_timer(state)
    rpc_vote_request=Raft.RequestVote.new(state.current_term,whoami(),get_last_log_index(state),get_last_log_term(state))
    broadcast_to_others(state,rpc_vote_request)
    # let candidate's extra state be a list of processes that voted for it.
    # need to vote for self
    list_of_voters=%{}
    # list_of_voters=Map.put(list_of_voters, state.current_term, MapSet)
    list_of_voters=Map.update(list_of_voters, state.current_term, MapSet.new([state]), fn set -> MapSet.put(set, state) end)
    candidate(state, list_of_voters)
  end

  @doc """
  This function implements the state machine for a process
  that is currently a candidate.

  `extra_state` can be used to store any additional information
  required, e.g., to count the number of votes received.
  """
  @spec candidate(%Raft{is_leader: false}, any()) :: no_return()
  def candidate(state, extra_state) do
    total_processes=length(state.view)
    vote_count=Map.get(extra_state, state.current_term, MapSet.new()) |> MapSet.size()
    state=
    if vote_count>total_processes/2 do
      # become leader
      IO.inspect("New leader elected #{whoami()}")
      IO.puts("candidate becomes leader")
      become_leader(state)
      state
    else
      state
    end

    receive do
      :election_time_up ->
        # call become candidate so that election restarts
        IO.puts("candidate #{whoami()} election time is up")
        become_candidate(state)
      
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest as a candidate
        IO.puts(
          "#{whoami()} Candidate received append entry for term #{term} " <>
            "with leader #{leader_id} " <>
            "(#{leader_commit_index})"
        )
        if term>=state.current_term do
            # update leader and become follower
            # IO.puts("state123")
            # IO.inspect(state)
            state=%{state | voted_for: nil}
            state=%{state | current_term: term}
            state=update_leader(state,leader_id)
            become_follower(state)
            # the follower would handle the response on next request
        else
          IO.puts("Received AppendEntry from a stale leader")
          candidate(state,extra_state)
        # raise "Not yet implemented"
        end

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an append entry response as a candidate
        IO.puts(
          "#{whoami()} Candidate received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )
        # IO.puts(
        #   "Candidate received append entry response #{term}," <>
        #     " index #{index}, succcess #{succ} -> not supposed to happen ig"
        # )
        if term > state.current_term do 
          state = %{state | voted_for: nil}
          state = %{state | current_term: term}
          become_follower(state)
        else
          candidate(state, extra_state)
        end
        # should not happen
        # candidate(state,extra_state)
        # raise "Not yet implemented"

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote response as a candidate.
        IO.puts(
          "#{whoami()} Candidate received RequestVote " <>
            "term = #{term}, candidate=#{candidate}"
        )
        # follow same routine as in leader's code and convert to follower
        if term>state.current_term do
          state = %{state | voted_for: nil}
          state = %{state | current_term: term}
          state=
          if last_log_term > get_last_log_term(state) do
            rpc_response=Raft.RequestVoteResponse.new(state.current_term,true)
            state=%{state | voted_for: candidate}
            send(sender,rpc_response)
            state
          else
            state=
            if last_log_term == get_last_log_term(state) do
              {state,rpc_response} = 
                if last_log_index >= get_last_log_index(state) do
                  n_state=%{state | voted_for: candidate}
                  {n_state,Raft.RequestVoteResponse.new(state.current_term,true)}
                else
                  {state,Raft.RequestVoteResponse.new(state.current_term,false)}
                end
              send(sender,rpc_response)
              state
            else
              rpc_response=Raft.RequestVoteResponse.new(state.current_term,false)
              send(sender, rpc_response)
              state
            end
          end
          become_follower(state)
        else
          rpc_response=Raft.RequestVoteResponse.new(state.current_term,false)
          send(sender, rpc_response)
          candidate(state, extra_state)
        end
        # leader(state,extra_state)

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle a RequestVoteResposne as a candidate.
        IO.puts(
          "#{whoami()} Candidate received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        cond do
          granted==true ->
            extra_state=Map.update(extra_state, state.current_term, MapSet.new([sender]), fn set -> MapSet.put(set, sender) end)
            candidate(state,extra_state)
          granted==false and term<=state.current_term ->
            candidate(state,extra_state)
          granted==false and term>state.current_term->
            become_follower(state)
        end
        # raise "Not yet implemented"

      # Messages from external clients.
      {sender, :nop} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, {:enq, item}} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, :deq} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        candidate(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        candidate(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {:candidate, state.current_term})
        candidate(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :candidate)
        candidate(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        candidate(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        candidate(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end
end

defmodule Raft.Client do
  import Emulation, only: [send: 2]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  @moduledoc """
  A client that can be used to connect and send
  requests to the RSM.
  """
  alias __MODULE__
  @enforce_keys [:leader]
  defstruct(leader: nil)

  @doc """
  Construct a new Raft Client. This takes an ID of
  any process that is in the RSM. We rely on
  redirect messages to find the correct leader.
  """
  @spec new_client(atom()) :: %Client{leader: atom()}
  def new_client(member) do
    %Client{leader: member}
  end

  @doc """
  Send a nop request to the RSM.
  """
  @spec nop(%Client{}) :: {:ok, %Client{}}
  def nop(client) do
    leader = client.leader
    send(leader, :nop)

    receive do
      {_, {:redirect, new_leader}} ->
        nop(%{client | leader: new_leader})

      {_, :ok} ->
        {:ok, client}
    end
  end

  @doc """
  Send a dequeue request to the RSM.
  """
  @spec deq(%Client{}) :: {:empty | {:value, any()}, %Client{}}
  def deq(client) do
    leader = client.leader
    send(leader, :deq)

    receive do
      {_, {:redirect, new_leader}} ->
        deq(%{client | leader: new_leader})

      {_, v} ->
        {v, client}
    end
  end

  @doc """
  Send an enqueue request to the RSM.
  """
  @spec enq(%Client{}, any()) :: {:ok, %Client{}}
  def enq(client, item) do
    leader = client.leader
    send(leader, {:enq, item})

    receive do
      {_, :ok} ->
        {:ok, client}

      {_, {:redirect, new_leader}} ->
        enq(%{client | leader: new_leader}, item)
    end
  end
end
