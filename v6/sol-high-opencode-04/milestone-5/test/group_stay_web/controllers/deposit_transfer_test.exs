defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  test "moves mixed funding in reverse allocation order and settles it at the destination", %{
    conn: conn
  } do
    setup_operations = [
      open_operation(%{
        "operation_id" => "open-credit-source",
        "group_id" => "credit-source",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "credit-room", "nightly_rate_cents" => 5_000}]
      }),
      payment_operation("pay-credit-source", "credit-source", 1_000),
      operation("create-credit", "cancel_group", %{
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }),
      open_operation(%{
        "operation_id" => "open-source",
        "group_id" => "source",
        "departure_on" => "2026-12-11",
        "rate_plan" => "advance_purchase",
        "rooms" => [
          %{"room_id" => "source-a", "nightly_rate_cents" => 5_000},
          %{"room_id" => "source-b", "nightly_rate_cents" => 5_000}
        ]
      }),
      payment_operation("pay-main", "source", 9_000),
      operation("apply-credit", "apply_hotel_credit", %{
        "group_id" => "source",
        "amount_cents" => 1_000
      }),
      open_operation(%{
        "operation_id" => "open-destination",
        "group_id" => "destination",
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "destination-a", "nightly_rate_cents" => 20_000},
          %{"room_id" => "destination-b", "nightly_rate_cents" => 20_000}
        ]
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: setup_operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    ledger_before =
      get(build_conn(), "/api/v1/ledger?on=2026-10-03") |> json_response(200)

    transfer =
      operation("transfer", "transfer_deposit", %{
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 6_000,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [transfer]})

    assert json_response(conn, 200) == %{
             "results" => [
               %{
                 "operation_id" => "transfer",
                 "status" => "applied",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 6_000,
                 "source_outstanding_deposit_cents" => 6_000,
                 "destination_outstanding_deposit_cents" => 2_000,
                 "source_revision" => 4,
                 "destination_revision" => 2
               }
             ]
           }

    assert get(build_conn(), "/api/v1/ledger?on=2026-10-03") |> json_response(200) ==
             ledger_before

    assert %{"data" => %{"rooms" => [source_a, source_b]}} =
             get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert source_a["cash_paid_cents"] == 4_000
    assert source_a["credit_paid_cents"] == 0
    assert source_b["cash_paid_cents"] == 0
    assert source_b["credit_paid_cents"] == 0

    assert %{"data" => %{"rooms" => [destination_a, destination_b]}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert destination_a["credit_paid_cents"] == 1_000
    assert destination_a["cash_paid_cents"] == 3_000
    assert destination_b["credit_paid_cents"] == 0
    assert destination_b["cash_paid_cents"] == 2_000

    assert %{
             "data" => %{
               "held_cents" => 9_000,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 5_000},
                 %{"group_id" => "source", "amount_cents" => 4_000}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)

    cancel = operation("cancel-destination", "cancel_group", %{"group_id" => "destination"})
    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [cancel]})

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ]
           } = json_response(conn, 200)

    assert %{"data" => %{"available_cents" => 1_100, "lots" => [lot]}} =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-03")
             |> json_response(200)

    assert lot["source_operation_id"] == "create-credit"
    assert lot["expires_on"] == "2027-10-03"

    chargeback =
      operation("chargeback-main", "charge_back_payment", %{
        "payment_operation_id" => "pay-main",
        "expected_revision" => 4
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [chargeback]})

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 9_000,
                 "outstanding_deposit_cents" => 10_000,
                 "revision" => 5
               }
             ]
           } = json_response(conn, 200)

    assert %{"data" => %{"revision" => 4}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 0,
               "refunded_cents" => 0,
               "charged_back_cents" => 9_000,
               "held_by_group" => []
             }
           } = get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)
  end

  test "rejects transfers in the required order without changing domain state", %{conn: conn} do
    setup_operations = [
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      payment_operation("pay-source", "source", 1_000),
      open_operation(%{"operation_id" => "open-destination", "group_id" => "destination"}),
      payment_operation("pay-destination", "destination", 19_000),
      open_operation(%{
        "operation_id" => "open-other",
        "group_id" => "other",
        "guest_id" => "guest-2"
      }),
      open_operation(%{
        "operation_id" => "open-inactive-source",
        "group_id" => "inactive-source"
      }),
      operation("cancel-inactive-source", "cancel_group", %{"group_id" => "inactive-source"}),
      open_operation(%{
        "operation_id" => "open-inactive-destination",
        "group_id" => "inactive-destination"
      }),
      operation("cancel-inactive-destination", "cancel_group", %{
        "group_id" => "inactive-destination"
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: setup_operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))

    rejected_transfers = [
      transfer_operation("missing-source", "missing-source", "missing-destination", 1),
      transfer_operation("missing-destination", "source", "missing-destination", 1, %{
        "expected_revision" => 0
      }),
      transfer_operation("stale-source", "source", "destination", 1, %{
        "expected_revision" => 0,
        "destination_expected_revision" => 0
      }),
      transfer_operation("stale-destination", "source", "destination", 1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 0
      }),
      transfer_operation("same-group", "source", "source", 1, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 2
      }),
      transfer_operation("different-guests", "source", "other", 1),
      transfer_operation("inactive-source", "inactive-source", "destination", 1),
      transfer_operation("inactive-destination", "source", "inactive-destination", 1),
      transfer_operation("invalid-amount", "source", "destination", 0),
      transfer_operation("source-exceeded", "source", "destination", 1_001),
      transfer_operation("destination-exceeded", "source", "destination", 600)
    ]

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: rejected_transfers})
    assert %{"results" => rejected} = json_response(conn, 200)

    assert Enum.map(rejected, & &1["code"]) == [
             "group_not_found",
             "group_not_found",
             "stale_revision",
             "stale_revision",
             "invalid_transfer",
             "invalid_transfer",
             "group_not_active",
             "group_not_active",
             "invalid_amount",
             "transfer_exceeds_held_funding",
             "transfer_exceeds_outstanding"
           ]

    assert Enum.at(rejected, 0)["group_id"] == "missing-source"
    assert Enum.at(rejected, 1)["group_id"] == "missing-destination"

    assert Enum.at(rejected, 2) == %{
             "operation_id" => "stale-source",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 0,
             "actual_revision" => 2
           }

    assert Enum.at(rejected, 3)["group_id"] == "destination"
    assert Enum.at(rejected, 6)["group_id"] == "inactive-source"
    assert Enum.at(rejected, 7)["group_id"] == "inactive-destination"

    assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
             get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{
             "data" => %{
               "revision" => 2,
               "deposit_paid_cents" => 19_000,
               "outstanding_deposit_cents" => 500
             }
           } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 20_000}} =
             get(build_conn(), "/api/v1/ledger?on=2026-10-03") |> json_response(200)
  end

  test "reductions and chargebacks follow transferred cash and revise every changed group", %{
    conn: conn
  } do
    setup_operations = [
      open_operation(%{"operation_id" => "open-z", "group_id" => "group-z"}),
      payment_operation("pay-main", "group-z", 3_000),
      open_operation(%{"operation_id" => "open-a", "group_id" => "group-a"}),
      open_operation(%{"operation_id" => "open-m", "group_id" => "group-m"})
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: setup_operations})
    assert %{"results" => [_, original_payment, _, _]} = json_response(conn, 200)

    assert %{"data" => statement_before} =
             get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)

    refute Map.has_key?(statement_before, "held_by_group")

    transfers = [
      transfer_operation("transfer-a", "group-z", "group-a", 1_000, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      }),
      transfer_operation("transfer-m", "group-z", "group-m", 800, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })
    ]

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: transfers})

    assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
             json_response(conn, 200)

    assert %{
             "data" => %{
               "held_cents" => 3_000,
               "held_by_group" => [
                 %{"group_id" => "group-a", "amount_cents" => 1_000},
                 %{"group_id" => "group-m", "amount_cents" => 800},
                 %{"group_id" => "group-z", "amount_cents" => 1_200}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)

    reduction =
      operation("reduce-main", "reduce_cash_payment", %{
        "payment_operation_id" => "pay-main",
        "amount_cents" => 1_000,
        "expected_revision" => 4
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [reduction]})

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "group-z",
                 "amount_cents" => 1_000,
                 "outstanding_deposit_cents" => 18_300,
                 "revision" => 5
               }
             ]
           } = json_response(conn, 200)

    assert_group_revision("group-a", 3)
    assert_group_revision("group-m", 3)
    assert_group_revision("group-z", 5)

    assert %{
             "data" => %{
               "held_cents" => 2_000,
               "reduced_cents" => 1_000,
               "held_by_group" => [
                 %{"group_id" => "group-a", "amount_cents" => 800},
                 %{"group_id" => "group-z", "amount_cents" => 1_200}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)

    chargeback =
      operation("charge-main", "charge_back_payment", %{
        "payment_operation_id" => "pay-main",
        "expected_revision" => 5
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [chargeback]})

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 2_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 6
               }
             ]
           } = json_response(conn, 200)

    assert_group_revision("group-a", 4)
    assert_group_revision("group-m", 3)
    assert_group_revision("group-z", 6)

    assert %{"data" => %{"held_cents" => 0, "held_by_group" => []}} =
             get(build_conn(), "/api/v1/payments/pay-main") |> json_response(200)

    conn =
      post(build_conn(), "/api/v1/partner-batches", %{
        operations: [payment_operation("pay-main", "group-z", 3_000)]
      })

    assert json_response(conn, 200) == %{"results" => [original_payment]}
  end

  test "transfers observe earlier batch operations and retry with their exact result", %{
    conn: conn
  } do
    transfer =
      transfer_operation("transfer-batch", "source", "destination", 400, %{
        "expected_revision" => 2,
        "destination_expected_revision" => 1
      })

    operations = [
      open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
      payment_operation("pay-source", "source", 1_000),
      open_operation(%{"operation_id" => "open-destination", "group_id" => "destination"}),
      transfer,
      payment_operation("pay-destination", "destination", 100),
      transfer
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => [_, _, _, original, payment, retried]} = json_response(conn, 200)

    assert original == %{
             "operation_id" => "transfer-batch",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 400,
             "source_outstanding_deposit_cents" => 18_900,
             "destination_outstanding_deposit_cents" => 19_100,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert payment["revision"] == 3
    assert retried == original

    assert %{"data" => ^original} =
             get(build_conn(), "/api/v1/operations/transfer-batch") |> json_response(200)

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 600}} =
             get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 500}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    conflict = Map.put(transfer, "amount_cents", 300)
    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [conflict]})
    assert %{"results" => [%{"code" => "operation_id_conflict"}]} = json_response(conn, 200)
  end

  test "preserves interleaved payment order when converted credit entitlement is rounded", %{
    conn: conn
  } do
    operations = [
      open_operation(%{
        "operation_id" => "open-source-a",
        "group_id" => "source-a",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "source-a-room", "nightly_rate_cents" => 50}]
      }),
      payment_operation("pay-a", "source-a", 10),
      open_operation(%{
        "operation_id" => "open-source-b",
        "group_id" => "source-b",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "source-b-room", "nightly_rate_cents" => 25}]
      }),
      payment_operation("pay-b", "source-b", 5),
      open_operation(%{
        "operation_id" => "open-destination",
        "group_id" => "destination",
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 75}]
      }),
      transfer_operation("transfer-a-1", "source-a", "destination", 5),
      transfer_operation("transfer-b", "source-b", "destination", 5),
      transfer_operation("transfer-a-2", "source-a", "destination", 5),
      operation("convert-destination", "cancel_group", %{
        "group_id" => "destination",
        "refund_method" => "hotel_credit"
      })
    ]

    conn = post(conn, "/api/v1/partner-batches", %{operations: operations})
    assert %{"results" => results} = json_response(conn, 200)
    assert Enum.all?(results, &(&1["status"] == "applied"))
    assert List.last(results)["credit_issued_cents"] == 17

    charge_a =
      operation("charge-a", "charge_back_payment", %{
        "payment_operation_id" => "pay-a",
        "expected_revision" => 4
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [charge_a]})

    assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 10}]} =
             json_response(conn, 200)

    assert %{"data" => %{"available_cents" => 5, "lots" => [%{"remaining_cents" => 5}]}} =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-03")
             |> json_response(200)

    charge_b =
      operation("charge-b", "charge_back_payment", %{
        "payment_operation_id" => "pay-b",
        "expected_revision" => 3
      })

    conn = post(build_conn(), "/api/v1/partner-batches", %{operations: [charge_b]})

    assert %{"results" => [%{"status" => "applied", "charged_back_cents" => 5}]} =
             json_response(conn, 200)

    assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2026-10-03")
             |> json_response(200)
  end

  defp assert_group_revision(group_id, revision) do
    assert %{"data" => %{"revision" => ^revision}} =
             get(build_conn(), "/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp transfer_operation(operation_id, source, destination, amount, extra \\ %{}) do
    operation(
      operation_id,
      "transfer_deposit",
      Map.merge(
        %{
          "source_group_id" => source,
          "destination_group_id" => destination,
          "amount_cents" => amount
        },
        extra
      )
    )
  end

  defp open_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, group_id, amount) do
    operation(operation_id, "record_cash_payment", %{
      "group_id" => group_id,
      "amount_cents" => amount
    })
  end

  defp operation(operation_id, type, fields) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => type,
        "occurred_on" => "2026-10-03"
      },
      fields
    )
  end
end
