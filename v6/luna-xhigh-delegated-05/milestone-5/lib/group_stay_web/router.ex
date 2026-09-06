defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", GroupStayWeb do
    pipe_through :api

    post "/v1/partner-batches", PartnerBatchesController, :create
    get "/v1/operations/:operation_id", OperationsController, :show
    get "/v1/payments/:payment_operation_id", PaymentsController, :show
    get "/v1/groups/:group_id", GroupsController, :show
    get "/v1/guests/:guest_id/credit", GuestCreditController, :show
    get "/v1/ledger", LedgerController, :show
  end
end
