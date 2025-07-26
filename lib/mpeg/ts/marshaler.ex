defprotocol MPEG.TS.Marshaler do
  @moduledoc """
  A protocol defining the behavior for marshaling MPEG-TS packets.
  """

  @fallback_to_any true

  @doc """
  Marshal a packet.
  """
  @spec marshal(t()) :: iodata()
  def marshal(packet)
end

defimpl MPEG.TS.Marshaler, for: List do
  def marshal(list), do: Enum.map(list, &MPEG.TS.Marshaler.marshal/1)
end

defimpl MPEG.TS.Marshaler, for: Map do
  # we consider this map, the PAT
  def marshal(pat) do
    Enum.map_join(pat, fn {program_number, pid} ->
      <<program_number::16, 0b111::3, pid::13>>
    end)
  end
end
