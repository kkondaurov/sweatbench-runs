defmodule GroupStay.WideDate do
  use Ecto.Type

  def type, do: :integer

  def cast(%Date{} = date), do: {:ok, date}
  def cast(_value), do: :error

  def load(days) when is_integer(days), do: {:ok, Date.from_gregorian_days(days)}
  def load(_value), do: :error

  def dump(%Date{} = date), do: {:ok, Date.to_gregorian_days(date)}
  def dump(_value), do: :error
end
