# Invoked by PersistenceTest in a fresh VM. Read results before submitting anything
# so replay cannot depend on domain modules or process-local state being warmed up.
[input_path, output_path] = System.argv()
operations = input_path |> File.read!() |> Jason.decode!()

stored_results =
  Enum.map(operations, fn operation ->
    {:ok, result} = GroupStay.Reservations.get_operation(operation["operation_id"])
    result
  end)

File.write!(
  output_path,
  Jason.encode!(%{
    stored_results: stored_results,
    replayed_results: GroupStay.Reservations.submit_batch(operations)
  })
)
