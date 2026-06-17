defmodule MPEG.TS.StreamAggregator do
  @moduledoc """
  This module's responsibility is to reduce a stream of TS packets packets into
  an ordered queue of PES ones. Accepts only packets belonging to the same
  elementary stream. This module is in support of the demuxer and acts as a
  PartialPES depayloader.
  """

  require Logger

  alias MPEG.TS.PartialPES
  alias MPEG.TS.PES

  defmodule Error do
    defexception [:message]

    @impl true
    def exception(reason) do
      %__MODULE__{message: reason}
    end
  end

  defstruct acc: :queue.new(), status: nil, strict?: false

  def new(opts \\ []) do
    opts = Keyword.validate!(opts, wait_rai?: true, strict?: false)
    status = if opts[:wait_rai?], do: :wait_rai, else: :wait_pusi
    %__MODULE__{status: status, strict?: opts[:strict?]}
  end

  def put_and_get(state = %{status: status}, packet = %{random_access_indicator: true})
      when status != :ready do
    state
    |> put_in([Access.key!(:status)], :ready)
    |> put_and_get(packet)
  end

  def put_and_get(state = %{status: :wait_pusi}, packet = %{pusi: true}) do
    state
    |> put_in([Access.key!(:status)], :ready)
    |> put_and_get(packet)
  end

  def put_and_get(state, pkt) do
    cond do
      :queue.is_empty(state.acc) and not pkt.pusi ->
        # If we start mid-PES (or after an aggregator reset), packets may begin
        # with continuations that do not carry a PES header (`pusi: false`).
        # Those packets cannot be depayloaded on their own, so we ignore them
        # until the next PES start arrives.
        Logger.debug(fn ->
          "Dropping PID #{pkt.pid} continuation packet: no PES start received yet"
        end)

        {[], state}

      true ->
        ppes = unmarshal_partial_pes!(pkt)

        if pkt.pusi and not :queue.is_empty(state.acc) do
          pes =
            state.acc
            |> :queue.to_list()
            |> depayload(state.strict?)

          {pes, %{state | acc: :queue.from_list([ppes])}}
        else
          {[], update_in(state, [Access.key!(:acc)], fn q -> :queue.in(ppes, q) end)}
        end
    end
  end

  def flush(state = %__MODULE__{acc: acc}) do
    pes =
      acc
      |> :queue.to_list()
      |> depayload(state.strict?)

    {pes, %__MODULE__{strict?: state.strict?}}
  end

  defp depayload([], _strict?) do
    []
  end

  defp depayload(packets = [leader | _], strict?) do
    stream_ids =
      packets
      |> Enum.map(fn x -> x.stream_id end)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    payload =
      packets
      |> Enum.map(fn x -> x.data end)
      |> Enum.join(<<>>)

    payload_size = byte_size(payload)
    leader_length = leader.length

    payload =
      cond do
        length(stream_ids) != 1 ->
          maybe_raise_or_drop(
            strict?,
            "PES group contains multiple stream_id: #{inspect(stream_ids)}"
          )

        leader_length == 0 ->
          # TODO: trim trailing stuffing bits? Seems to make no difference.
          payload

        payload_size > leader_length ->
          <<payload::binary-size(^leader_length)-unit(8), _rest::binary>> = payload
          payload

        payload_size == leader_length ->
          payload

        true ->
          maybe_raise_or_drop(
            strict?,
            "Invalid PES, size mismatch (have=#{payload_size}, want=#{leader_length})"
          )
      end

    if is_nil(payload) do
      []
    else
      List.wrap(%PES{
        data: payload,
        stream_id: leader.stream_id,
        pts: leader.pts,
        dts: leader.dts,
        is_aligned: leader.is_aligned,
        discontinuity: leader.discontinuity
      })
    end
  end

  defp maybe_raise_or_drop(true, message), do: raise(Error, message)
  defp maybe_raise_or_drop(false, _message), do: nil

  defp unmarshal_partial_pes!(packet) do
    case PartialPES.unmarshal(packet.payload, packet.pusi) do
      {:ok, pes} ->
        %{pes | discontinuity: packet.discontinuity}

      {:error, reason} ->
        raise Error, "PES unmarshal error: #{inspect(reason)}"
    end
  end
end
