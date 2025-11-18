defmodule MPEG.TS.Packet do
  @ts_packet_size 188
  @ts_header_size 4
  @ts_payload_size @ts_packet_size - @ts_header_size

  @type adaptation_control_t :: :payload | :adaptation | :adaptation_and_payload | :reserved

  @type scrambling_t :: :no | :even_key | :odd_key | :reserved

  @type pid_class_t :: :pat | :psi | :null_packet | :unsupported
  @type pid_t :: pos_integer()

  @type adaptation_t :: %{}

  @type payload_t :: bitstring()
  @type t :: %__MODULE__{
          payload: payload_t(),
          # payload unit start indicator
          pusi: boolean(),
          pid: pid_t(),
          pid_class: pid_class_t(),
          continuity_counter: binary(),
          scrambling: scrambling_t(),
          discontinuity_indicator: boolean(),
          random_access_indicator: boolean(),
          pcr: pos_integer(),
          discontinuity: boolean()
        }
  @derive {Inspect,
           only: [
             :pid,
             :pid_class,
             :pusi,
             :continuity_counter,
             :discontinuity_indicator,
             :random_access_indicator,
             :payload,
             :discontinuity
           ]}
  defstruct [
    :payload,
    :pid,
    :pid_class,
    :continuity_counter,
    :pcr,
    pusi: false,
    scrambling: :no,
    discontinuity_indicator: false,
    random_access_indicator: false,
    discontinuity: false
  ]

  @type parse_error_t ::
          :invalid_data | :invalid_packet | :unsupported_packet

  @spec new(payload :: payload_t(), opts :: keyword()) :: t()
  def new(payload, opts \\ []) do
    struct(%__MODULE__{payload: payload}, opts)
  end

  @spec parse(binary()) ::
          {:ok, t} | {:error, parse_error_t, binary()}
  def parse(
        data = <<
          0x47::8,
          _transport_error_indicator::1,
          payload_unit_start_indicator::1,
          _transport_priority::1,
          pid::13,
          transport_scrambling_control::2,
          adaptation_field_control::2,
          continuity_counter::4,
          optional_fields::@ts_payload_size-binary
        >>
      ) do
    with adaptation_field_id = parse_adaptation_field_control(adaptation_field_control),
         pid_class = parse_pid_class(pid),
         pusi = parse_flag(payload_unit_start_indicator),
         scrambling = parse_scrambling_control(transport_scrambling_control),
         {:ok, adaptation, data} <- parse_payload(optional_fields, adaptation_field_id, pid_class) do
      packet =
        %__MODULE__{
          pusi: pusi,
          pid: pid,
          pid_class: pid_class,
          payload: data,
          scrambling: scrambling,
          continuity_counter: continuity_counter,
          discontinuity_indicator: Map.get(adaptation, :discontinuity_indicator, false),
          random_access_indicator: Map.get(adaptation, :random_access_indicator, false),
          pcr: Map.get(adaptation, :pcr, nil)
        }

      {:ok, packet}
    else
      {:error, reason} -> {:error, reason, data}
    end
  end

  def parse(data = <<0x47::8, _::binary>>) when byte_size(data) < @ts_packet_size,
    do: {:error, :not_enough_data, data}

  def parse(data), do: {:error, :invalid_data, data}

  def packet_size(), do: @ts_packet_size

  @spec parse_many(binary()) :: [{:error, parse_error_t(), binary()} | {:ok, t}]
  def parse_many(data), do: parse_many(data, [])

  defp parse_many(<<>>, acc), do: Enum.reverse(acc)

  defp parse_many(<<packet::binary-@ts_packet_size, rest::binary>>, acc),
    do: parse_many(rest, [parse(packet) | acc])

  defp parse_many(data, acc) when byte_size(data) < @ts_packet_size,
    do: parse_many(<<>>, [parse(data) | acc])

  defp parse_adaptation_field_control(0b01), do: :payload
  defp parse_adaptation_field_control(0b10), do: :adaptation
  defp parse_adaptation_field_control(0b11), do: :adaptation_and_payload
  defp parse_adaptation_field_control(0b00), do: :reserved

  defp parse_scrambling_control(0b00), do: :no
  defp parse_scrambling_control(0b01), do: :reserved
  defp parse_scrambling_control(0b10), do: :even_key
  defp parse_scrambling_control(0b11), do: :odd_key

  defp parse_pid_class(0x0000), do: :pat
  defp parse_pid_class(id) when id in 0x0020..0x1FFA or id in 0x1FFC..0x1FFE, do: :psi
  defp parse_pid_class(0x1FFF), do: :null_packet
  defp parse_pid_class(_), do: :unsupported

  defp parse_flag(0b1), do: true
  defp parse_flag(0b0), do: false

  @spec parse_payload(binary(), adaptation_control_t(), pid_class_t()) ::
          {:ok, map(), bitstring()} | {:error, parse_error_t()}
  defp parse_payload(
         <<adaptation_field_length::8, adaptation_field::binary-size(adaptation_field_length),
           _rest::binary>>,
         :adaptation,
         _
       ) do
    with {:ok, adaptation} <- parse_adaptation_field(adaptation_field) do
      {:ok, adaptation, <<>>}
    end
  end

  defp parse_payload(_, :reserved, _), do: {:error, :unsupported_packet}
  defp parse_payload(_, :payload, :null_packet), do: {:ok, %{}, <<>>}

  defp parse_payload(
         <<
           adaptation_field_length::8,
           adaptation_field::binary-size(adaptation_field_length),
           payload::bitstring
         >>,
         :adaptation_and_payload,
         pid
       ) do
    with {:ok, %{}, payload} <- parse_payload(payload, :payload, pid),
         {:ok, adaptation} <-
           parse_adaptation_field(adaptation_field) do
      {:ok, adaptation, payload}
    end
  end

  defp parse_payload(payload, :payload, :psi), do: {:ok, %{}, payload}

  # <<table_id::8, 1::1, 0::1, 3::2, 0::2, section_length::10, table_id_ext::16, 3::2,
  #   version::5, active::1, section::8, last_section::8, rest::bitstring>>,
  defp parse_payload(payload, :payload, :pat), do: {:ok, %{}, payload}
  defp parse_payload(_, _, _), do: {:error, :unsupported_packet}

  defp parse_adaptation_field(<<>>) do
    # Happens when size of adaptation field is 0.
    # We saw ffmpeg producing this kind of payloads.
    {:ok, %{}}
  end

  defp parse_adaptation_field(<<
         discontinuity_indicator::1,
         random_access_indicator::1,
         _elementary_stream_priority_indicator::1,
         has_pcr::1,
         _has_opcr::1,
         _has_splicing_point::1,
         _is_transport_private_data::1,
         _has_adaptation_field_extension::1,
         rest::binary
       >>) do
    discontinuity_indicator = parse_flag(discontinuity_indicator)
    random_access_indicator = parse_flag(random_access_indicator)
    has_pcr = parse_flag(has_pcr)

    adaptation =
      if has_pcr do
        {pcr, _} = parse_pcr(rest)
        %{pcr: pcr}
      else
        %{}
      end

    adaptation =
      Map.merge(adaptation, %{
        discontinuity_indicator: discontinuity_indicator,
        random_access_indicator: random_access_indicator
      })

    {:ok, adaptation}
  end

  defp parse_pcr(<<
         base::33,
         _reserved::6,
         extension::9,
         rest::binary
       >>) do
    # PCR_base is in 90 kHz units, PCR_extension is in 27 MHz units
    # Convert each part separately to avoid clock rate confusion
    pcr_ns = MPEG.TS.convert_ts_to_ns(base) + round(extension * 1.0e9 / 27_000_000)
    {pcr_ns, rest}
  end

  defimpl MPEG.TS.Marshaler do
    @ts_payload_size 184
    @scrambling_control [no: 0, reserved: 1, even_key: 2, odd_key: 3]

    def marshal(packet) do
      adaptation = serialize_adaptation_field(packet)

      adaptation_field_value =
        cond do
          adaptation != [] and byte_size(packet.payload) == 0 -> 2
          adaptation != [] and byte_size(packet.payload) != 0 -> 3
          true -> 1
        end

      [
        0x47,
        <<0::1, bool_to_int(packet.pusi)::1, 0::1, packet.pid::13,
          @scrambling_control[packet.scrambling]::2, adaptation_field_value::2,
          packet.continuity_counter::4>>,
        adaptation,
        packet.payload
      ]
    end

    defp serialize_adaptation_field(packet) do
      case adaptation_field_present?(packet) do
        true ->
          pcr_data = serialize_pcr(packet.pcr)
          header_size = byte_size(pcr_data) + 2
          stuffing_bytes = @ts_payload_size - byte_size(packet.payload) - header_size

          [
            header_size + stuffing_bytes - 1,
            <<bool_to_int(packet.discontinuity_indicator)::1,
              bool_to_int(packet.random_access_indicator)::1, 0::1,
              bool_to_int(pcr_data != <<>>)::1, 0::4>>,
            pcr_data,
            filler_data(stuffing_bytes)
          ]

        false ->
          case @ts_payload_size - byte_size(packet.payload) do
            0 -> []
            1 -> [0]
            stuffing_bytes -> [stuffing_bytes - 1, 0, filler_data(stuffing_bytes - 2)]
          end
      end
    end

    defp adaptation_field_present?(%{discontinuity_indicator: true}), do: true
    defp adaptation_field_present?(%{random_access_indicator: true}), do: true
    defp adaptation_field_present?(%{pcr: nil}), do: false
    defp adaptation_field_present?(_packet), do: true

    defp serialize_pcr(nil), do: <<>>

    defp serialize_pcr(pcr) do
      # Convert nanoseconds to 27 MHz units
      pcr_27mhz = round(pcr * 27_000_000 / 1.0e9)
      # Split into base (90 kHz) and extension (27 MHz fractional part)
      <<div(pcr_27mhz, 300)::33, 0b111111::6, rem(pcr_27mhz, 300)::9>>
    end

    defp bool_to_int(true), do: 1
    defp bool_to_int(_), do: 0

    defp filler_data(times), do: :binary.copy(<<0xFF>>, times)
  end
end
