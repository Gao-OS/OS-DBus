ExUnit.start(exclude: [:interop, :e2e])

tag_present? = fn filters, tag ->
  Enum.any?(filters, fn
    ^tag -> true
    {^tag, true} -> true
    {^tag, _value} -> true
    _other -> false
  end)
end

config = ExUnit.configuration()
include = Keyword.get(config, :include, [])
exclude = Keyword.get(config, :exclude, [])

e2e_included? = tag_present?.(include, :e2e)
e2e_excluded? = tag_present?.(exclude, :e2e)
e2e_env? = System.get_env("E2E_BACKEND") != nil or System.get_env("E2E_GATE") != nil

if e2e_included? or (e2e_env? and not e2e_excluded?) do
  GaoBusTest.E2E.ScenarioCase.prepare_backend_availability!()
end
