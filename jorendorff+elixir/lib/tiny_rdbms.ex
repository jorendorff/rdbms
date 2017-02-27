defmodule TinyRdbms do
  @moduledoc """
  Documentation for TinyRdbms.
  """

  def load_table(filename) do
    File.stream!(filename) |>
      CSV.decode(headers: true) |>
      Enum.to_list()
  end

  def load(dir) do
    File.ls!(dir) |>
      Enum.filter(fn(f) -> String.ends_with?(f, ".csv") end) |>
      Enum.map(fn(f) ->
        {String.downcase(String.slice(f, 0..-5)),
         TinyRdbms.load_table(Path.join(dir, f))}
      end) |>
      Enum.reduce(%{}, fn({k, v}, db) -> Map.put(db, k, v) end)
  end

  def run_query(database, query) do
    ast = Sql.parse_select_stmt!(query)
    ast |> inspect() |> IO.puts()
    [table_name] = ast.from

    results = Map.get(database, String.downcase(table_name))

    # Evalute WHERE clause.
    where_expr = ast.where
    results = Enum.filter(results, fn(row) ->
      is_sql_value_truthy?(eval_expr(row, where_expr))
    end)

    # Execute SELECT clause.
    select_exprs = ast.select
    results = Enum.map(results, fn(row) ->
      # For each row, evaluate each selected expression.
      Enum.map(select_exprs, fn(expr) -> eval_expr(row, expr) end)
    end)

    results
  end

  defp eval_expr(row, expr) do
    case expr do
      {:identifier, x} -> row[x]
      {:number, n} -> n
      {:string, s} -> s
      {:is_null, subexpr} ->
        val = eval_expr(row, subexpr)
        is_sql_value_null?(val)
      {:=, left_expr, right_expr} ->
        left_val = eval_expr(row, left_expr)
        right_val = eval_expr(row, right_expr)
        sql_equals?(left_val, right_val)
      _ -> raise ArgumentError, message: "internal error: unrecognized expr #{inspect(expr)}"
    end
  end

  defp is_sql_value_null?(v) do
    v == :nil || v == ""
  end

  defp is_sql_value_truthy?(v) do
    v == true || (is_integer(v) && v != 0)
  end

  defp sql_equals?(left, right) do
    left == right ||
      ((is_binary(left) || is_integer(left)) &&
       (is_binary(right) || is_integer(right)) &&
       to_string(left) == to_string(right))
  end
end


defmodule Sql do

  @doc """
  Break the given SQL string `s` into tokens.

  Return the list of tokens. SQL keywords, operators, etc. are represented
  as Elixir keywords. Identifiers and literals are represented as pairs,
  `{:token_type, value}`. The token types are `:identifier`, `:number`, and
  `:string`.

  ## Examples

      iex> Sql.tokenize("SELECT * FROM Student")
      [:select, :*, :from, {:identifier, "Student"}]
      iex> Sql.tokenize("WHERE name = '")
      [:where, {:identifier, "name"}, :=, {:error, "unrecognized character: '"}]

  """
  def tokenize(s) do
    token_re = ~r/(?:\s*)(\w+|[0-9]\w+|'(?:[^']|'')*'|>=|<=|<>|.)(?:\s*)/
    Regex.scan(token_re, s, capture: :all_but_first) |>
      Enum.map(&match_to_token/1)
  end

  # Convert a single token regex match into a token.
  defp match_to_token([token_str]) do
    case String.downcase(token_str) do
      "all" -> :all
      "and" -> :and
      "as" -> :as
      "asc" -> :asc
      "between" -> :between
      "by" -> :by
      "desc" -> :desc
      "distinct" -> :distinct
      "exists" -> :exists
      "from" -> :from
      "group" -> :group
      "having" -> :having
      "insert" -> :insert
      "is" -> :is
      "not" -> :not
      "null" -> :null
      "or" -> :or
      "order" -> :order
      "select" -> :select
      "set" -> :set
      "union" -> :union
      "update" -> :update
      "values" -> :values
      "where" -> :where
      "*" -> :*
      "." -> :.
      "," -> :','
      "(" -> :'('
      ")" -> :')'
      "=" -> :=
      ">=" -> :'>='
      "<=" -> :'<='
      ">" -> :'>'
      "<" -> :'<'
      "<>" -> :'<>'
      _ ->
        cond do
          String.match?(token_str, ~r/^[0-9]/) ->
            {n, ""} = Integer.parse(token_str)
            {:number, n}
          String.match?(token_str, ~r/^[a-z]/i) ->
            {:identifier, token_str}
          String.match?(token_str, ~r/^'.*'$/) ->
            {:string, String.slice(token_str, 1..-2)} # TODO: handle doubled quotes
          true -> {:error, "unrecognized character: #{token_str}"}
        end
    end
  end

  def parse_select_stmt!(sql) do
    {%{}, tokenize(sql)} |>
      parse_clause!(:select, &parse_exprs!/1, required: true) |>
      parse_clause!(:from, &parse_tables!/1) |>
      parse_clause!(:where, &parse_expr!/1) |>
      parse_clause_2!(:group, :by, &parse_exprs!/1) |>
      parse_clause!(:having, &parse_expr!/1) |>
      parse_clause_2!(:order, :by, &parse_exprs!/1) |>
      check_done!()
  end

  defp parse_exprs!(sql) do
    {expr, tail} = parse_expr!(sql)
    case tail do
      [:',' | more] ->
        {exprs, rest} = parse_exprs!(more)
        {[expr | exprs], rest}
      _ -> {[expr], tail}
    end
  end

  defp parse_prim!(sql) do
    case sql do
      [{:identifier, _} | tail] -> {hd(sql), tail}
      [{:number, _} | tail] -> {hd(sql), tail}
      [{:string, _} | tail] -> {hd(sql), tail}
      _ -> raise ArgumentError, message: "identifier or literal expected"
    end
  end

  defp parse_expr!(sql) do
    {prim, rest} = parse_prim!(sql)
    case rest do
      [:= | rest] ->
        {rhs, rest} = parse_prim!(rest)
        {{:=, prim, rhs}, rest}
      [:is, :null | rest] ->
        {{:is_null, prim}, rest}
      _ -> {prim, rest}
    end
  end

  defp parse_table!(sql) do
    case sql do
      [{:identifier, x} | rest] -> {x, rest}
      _ -> raise ArgumentError, message: "table name expected"
    end
  end

  defp parse_tables!(sql) do
    {table, rest} = parse_table!(sql)
    case rest do
      [:',' | rest] ->
        {tables, rest} = parse_tables!(rest)
        {[table | tables], rest}
      _ -> {[table], rest}
    end
  end

  defp parse_clause!({ast, sql}, keyword, parser, keywords \\ []) do
    case sql do
      [^keyword | tail] ->
        {clause_ast, rest} = parser.(tail)
        {Map.put(ast, keyword, clause_ast), rest}
      _ ->
        if Keyword.get(keywords, :required, false) do
          raise ArgumentError, message: "#{keyword} expected"
        else
          {Map.put(ast, keyword, :nil), sql}
        end
    end
  end

  defp parse_clause_2!({ast, sql}, kw1, kw2, parser) do
    case sql do
      [^kw1, ^kw2 | tail] ->
        {clause_ast, rest} = parser.(tail)
        {Map.put(ast, kw1, clause_ast), rest}
      _ ->
        {Map.put(ast, kw1, :nil), sql}
    end
  end

  defp check_done!({ast, sql}) do
    case sql do
      [] -> ast
      _ ->
        ast |> inspect() |> IO.puts()
        sql |> inspect() |> IO.puts()
        raise ArgumentError, message: "extra stuff at end of SQL"
    end
  end
end
