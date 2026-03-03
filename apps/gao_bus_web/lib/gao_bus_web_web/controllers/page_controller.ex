defmodule GaoBusWebWeb.PageController do
  use GaoBusWebWeb, :controller
  @moduledoc false

  def home(conn, _params) do
    render(conn, :home)
  end
end
