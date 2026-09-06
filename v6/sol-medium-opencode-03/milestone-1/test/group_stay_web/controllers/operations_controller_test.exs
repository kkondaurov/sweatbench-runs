defmodule GroupStayWeb.OperationsControllerTest do
  use GroupStayWeb.ConnCase

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_501}
        ]
      },
      overrides
    )
  end

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  test "opens a group, calculates each room deposit, and returns it through the read API", %{
    conn: conn
  } do
    response = conn |> submit([open_operation()]) |> json_response(200)

    assert response == %{
             "results" => [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_502,
                 "revision" => 1
               }
             ]
           }

    group =
      build_conn() |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert group == %{
             "group_id" => "group-81",
             "guest_id" => "guest-22",
             "property_id" => "ams-canal",
             "booked_on" => "2026-10-03",
             "arrival_on" => "2026-12-10",
             "departure_on" => "2026-12-13",
             "rate_plan" => "flexible",
             "status" => "active",
             "revision" => 1,
             "rooms" => [
               %{"room_id" => "room-a", "nightly_rate_cents" => 15_001},
               %{"room_id" => "room-b", "nightly_rate_cents" => 17_501}
             ],
             "lodging_total_cents" => 97_506,
             "deposit_due_cents" => 19_502,
             "deposit_paid_cents" => 0,
             "outstanding_deposit_cents" => 19_502
           }
  end

  test "processes payments and reschedules in batch order with revisions", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "pay-1",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 5_000,
          "expected_revision" => 1
        },
        %{
          "operation_id" => "move-1",
          "type" => "reschedule_group",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "new_arrival_on" => "2026-12-20",
          "expected_revision" => 2
        }
      ])
      |> json_response(200)

    assert [opened, paid, moved] = response["results"]
    assert opened["revision"] == 1

    assert paid == %{
             "operation_id" => "pay-1",
             "status" => "applied",
             "group_id" => "group-81",
             "amount_cents" => 5_000,
             "outstanding_deposit_cents" => 14_502,
             "revision" => 2
           }

    assert moved == %{
             "operation_id" => "move-1",
             "status" => "applied",
             "group_id" => "group-81",
             "new_arrival_on" => "2026-12-20",
             "new_departure_on" => "2026-12-23",
             "revision" => 3
           }
  end

  test "rejects stale changes before other validation and leaves state unchanged", %{conn: conn} do
    response =
      conn
      |> submit([
        open_operation(),
        %{
          "operation_id" => "stale-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => -1,
          "expected_revision" => 9
        },
        %{
          "operation_id" => "good-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-81",
          "amount_cents" => 1_000,
          "expected_revision" => 1
        }
      ])
      |> json_response(200)

    assert Enum.at(response["results"], 1) == %{
             "operation_id" => "stale-pay",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "group-81",
             "expected_revision" => 9,
             "actual_revision" => 1
           }

    assert Enum.at(response["results"], 2)["revision"] == 2
  end

  test "serializes simultaneous updates at the expected revision", %{conn: conn} do
    conn |> submit([open_operation()]) |> json_response(200)

    results =
      1..5
      |> Task.async_stream(
        fn number ->
          operation =
            payment("concurrent-#{number}", "group-81", 1)
            |> Map.put("expected_revision", 1)

          [result] = GroupStay.Operations.submit([operation])
          result
        end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1.status == "applied")) == 1
    assert Enum.count(results, &(&1[:code] == "stale_revision")) == 4

    group =
      build_conn() |> get("/api/v1/groups/group-81") |> json_response(200) |> Map.fetch!("data")

    assert group["revision"] == 2
    assert group["deposit_paid_cents"] == 1
  end

  test "settles flexible cancellations and reports ledger totals", %{conn: conn} do
    operations = [
      open_operation(),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      %{
        "operation_id" => "late-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-27",
        "group_id" => "group-81",
        "amount_cents" => 1
      }
    ]

    response = conn |> submit(operations) |> json_response(200)

    assert Enum.at(response["results"], 2) == %{
             "operation_id" => "cancel-1",
             "status" => "applied",
             "group_id" => "group-81",
             "refunded_cents" => 5_000,
             "retained_cents" => 0,
             "revision" => 3
           }

    assert Enum.at(response["results"], 3)["code"] == "group_not_active"

    assert build_conn() |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 0
             }
           }
  end

  test "retains late flexible and all advance-purchase cash", %{conn: conn} do
    advance =
      open_operation(%{
        "operation_id" => "open-advance",
        "group_id" => "advance",
        "rate_plan" => "advance_purchase"
      })

    operations = [
      open_operation(),
      payment("pay-flex", "group-81", 1_000),
      cancellation("cancel-flex", "group-81", "2026-11-27"),
      advance,
      payment("pay-advance", "advance", 2_000),
      cancellation("cancel-advance", "advance", "2026-10-05")
    ]

    conn |> submit(operations) |> json_response(200)

    assert build_conn() |> get("/api/v1/ledger") |> json_response(200) == %{
             "data" => %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3_000
             }
           }
  end

  test "returns stable validation errors and continues after rejections", %{conn: conn} do
    operations = [
      open_operation(%{"arrival_on" => "bad-date"}),
      open_operation(%{"rooms" => []}),
      open_operation(%{"rate_plan" => "mystery"}),
      open_operation(),
      open_operation(%{"operation_id" => "duplicate"}),
      payment("bad-amount", "group-81", 0),
      payment("too-much", "group-81", 99_999),
      payment("missing", "missing", 1),
      Map.delete(payment("missing-amount", "group-81", 1), "amount_cents"),
      open_operation(%{"operation_id" => "missing-rooms"}) |> Map.delete("rooms"),
      %{"operation_id" => "unknown", "type" => "wat", "occurred_on" => "2026-01-01"},
      %{"type" => "cancel_group", "occurred_on" => "2026-01-01", "group_id" => "group-81"}
    ]

    codes =
      conn
      |> submit(operations)
      |> json_response(200)
      |> Map.fetch!("results")
      |> Enum.map(& &1["code"])

    assert codes == [
             "invalid_stay",
             "invalid_rooms",
             "invalid_rate_plan",
             nil,
             "group_already_exists",
             "invalid_amount",
             "payment_exceeds_outstanding",
             "group_not_found",
             "invalid_operation",
             "invalid_operation",
             "invalid_operation",
             "invalid_operation"
           ]
  end

  test "validates the batch and missing group read", %{conn: conn} do
    assert conn |> post("/api/v1/partner-batches", %{}) |> json_response(422) == %{
             "error" => %{"code" => "invalid_batch"}
           }

    assert build_conn() |> get("/api/v1/groups/missing") |> json_response(404) == %{
             "error" => %{"code" => "group_not_found"}
           }
  end

  defp payment(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp cancellation(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end
end
