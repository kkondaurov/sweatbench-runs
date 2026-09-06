defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", GroupStayWeb do
    pipe_through :api

    post "/v1/partner-batches", PartnerBatchController, :create
    get "/v1/groups/:group_id", GroupController, :show
    get "/v1/operations/:operation_id", OperationController, :show
    get "/v1/guests/:guest_id/credit", CreditController, :show
    get "/v1/ledger", LedgerController, :show
  end
end
