concern :Named do
  # The sort key and the filter value of a thing with a name: LOWER(name), the `data-value` the room form's filter menu matches and
  # the order the sidebar's shared rooms and the people lists keep. A model with a `name` column says `include :Named`.
  expr :lower_name, type: :string, sql: "LOWER({t}.name)"
end
