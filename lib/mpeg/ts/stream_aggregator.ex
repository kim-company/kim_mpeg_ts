defmodule MPEG.TS.StreamAggregator do
  @moduledoc """
  This module's responsibility is to reduce a stream of TS packets packets into
  an ordered queue of PES ones. Accepts only packets belonging to the same
  elementary stream. This module is in support of the demuxer and acts as a
  PartialPES depayloader.
  """

  alias MPEG.TS.PartialPES
  alias MPEG.TS.PES

  defmodule Error do
    defexception [:message]

    @impl true
    def exception(reason) do
      %__MODULE__{message: reason}
    end
  end

  defstruct acc: :queue.new(), status: nil

  def new(opts \\ []) do
    opts = Keyword.validate!(opts, wait_rai?: true)
    status = if opts[:wait_rai?], do: :wait_rai, else: :wait_pusi
    %__MODULE__{status: status}
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
        {[], state}

      true ->
        ppes = unmarshal_partial_pes!(pkt)

        if pkt.pusi and not :queue.is_empty(state.acc) do
          get_and_update_in(state, [Access.key!(:acc)], fn acc ->
            pes =
              acc
              |> :queue.to_list()
              |> depayload()

            {pes, :queue.from_list([ppes])}
          end)
        else
          {[], update_in(state, [Access.key!(:acc)], fn q -> :queue.in(ppes, q) end)}
        end
    end
  end

  def flush(%__MODULE__{acc: acc}) do
    pes =
      acc
      |> :queue.to_list()
      |> depayload()

    {pes, %__MODULE__{}}
  end

  defp depayload([]) do
    []
  end

  defp depayload(packets = [leader | _]) do
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

    payload =
      cond do
        length(stream_ids) != 1 ->
          raise Error, "PES group contains multiple stream_id: #{inspect(stream_ids)}"

        leader.length == 0 ->
          # TODO: trim trailing stuffing bits? Seems to make no difference.
          payload

        payload_size > leader.length ->
          <<payload::binary-size(leader.length)-unit(8), _rest::binary>> = payload
          payload

        payload_size == leader.length ->
          payload

        true ->
          raise Error, "Invalid PES, size mismatch (have=#{payload_size}, want=#{leader.length})"
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

  defp unmarshal_partial_pes!(packet) do
    case PartialPES.unmarshal(packet.payload, packet.pusi) do
      {:ok, pes} ->
        %{pes | discontinuity: packet.discontinuity}

      {:error, reason} ->
        raise Error, "PES unmarshal error: #{inspect(reason)}"
    end
  end
end
