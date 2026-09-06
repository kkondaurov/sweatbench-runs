defmodule GroupStay.FinancePostingDate do
  use Ecto.Type

  def type, do: :string

  def cast(%Date{} = date), do: {:ok, date}
  def cast(_value), do: :error

  def load(days) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} -> {:ok, Date.from_gregorian_days(days)}
      _ -> :error
    end
  end

  def load(_value), do: :error

  def dump(%Date{} = date) do
    days = date |> Date.to_gregorian_days() |> Integer.to_string() |> String.pad_leading(12, "0")
    {:ok, days}
  end

  def dump(_value), do: :error
end
