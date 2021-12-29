
defmodule Xpeg do

  def collect_captures(stack, acc, caps) do
    case {stack, acc} do
      {[ {:open, s} | stack], _} ->
        collect_captures(stack, [ {:open, s} | acc], caps)
      {[ {:close, sc} | stack], [{:open, so} | acc]} ->
        len = Enum.count(so) - Enum.count(sc)
        cap = to_string(Enum.take(so, len))
        collect_captures(stack, acc, [cap | caps])
      {_, acc} ->
        {acc, caps}
    end
  end

  def collect_captures(state) do
    {cap_stack, captures} = state.cap_stack
                            |> Enum.reverse
                            |> Xpeg.collect_captures([], [])
    %{state |
      cap_stack: cap_stack,
      captures: captures ++ state.captures
    }
  end

  def trace(state, ip, cmd, s) do
    if state.do_trace do
      ip = to_string(ip) |> String.pad_trailing(5, " ")
      cmd = cmd |> String.pad_trailing(18, " ")
      s = to_string(s) |> String.slice(0, 20) |> String.pad_trailing(20, " ")
      IO.puts("   #{ip} | #{s} | #{cmd} | ")
    end
  end

  defp emit_inst(ip, inst) do

    case inst do

      {:nop} -> quote do
        Xpeg.trace(state, unquote(ip), "nop", s)
        {state, s, unquote(ip+1)}
      end

      {:any, n} -> quote do
        if Enum.count(s) >= unquote(n) do
          {state, Enum.drop(s, unquote(n)), unquote(ip+1)}
        else
          {state, s, :fail}
        end
      end

      {:chr, c} -> quote do
        Xpeg.trace(state, unquote(ip), "chr #{unquote(c)}", s)
        case s do
          [unquote(c) | s] -> {state, s, unquote(ip+1)}
          _ -> {state, s, :fail}
        end
      end

      {:set, cs} -> quote do
        Xpeg.trace(state, unquote(ip), "set", s)
        case s do
          [c | s ] when c in unquote(MapSet.to_list(cs)) -> {state, s, unquote(ip+1)}
          _ -> {state, s, :fail}
        end
      end

      {:return} -> quote do
        Xpeg.trace(state, unquote(ip), "return #{inspect(state.ret_stack)}", s)
        case state.ret_stack do
          [ip | rest] -> {%{state | ret_stack: rest}, s, ip}
          [] -> {%{state | status: :ok}, s, ip}
        end
      end

      {:choice, off_back, off_commit} -> quote do
        Xpeg.trace(state, unquote(ip), "choice #{unquote(off_back)} #{unquote(off_commit)}", s)
        frame = %{
          ip_back: ip + unquote(off_back),
          ip_commit: ip + unquote(off_commit),
          ret_stack: state.ret_stack,
          cap_stack: state.cap_stack,
          s: s
        }
        state = %{state | back_stack: [frame | state.back_stack]}
        {state, s, unquote(ip+1)}
      end

      {:commit} -> quote do
        Xpeg.trace(state, unquote(ip), "commit", s)
        [frame | back_stack] = state.back_stack
        state = %{state | back_stack: back_stack}
        {state, s, frame.ip_commit}
      end

      {:call, addr} -> quote do
        Xpeg.trace(state, unquote(ip), "call #{unquote addr}", s)
        state = %{state | ret_stack: [ip+1 | state.ret_stack]}
        {state, s, unquote(addr)}
      end

      {:capopen} -> quote do
        Xpeg.trace(state, unquote(ip), "capopen", s)
        state = %{state | cap_stack: [{:open, s} | state.cap_stack]}
        {state, s, unquote(ip+1)}
      end

      {:capclose,} -> quote do
        Xpeg.trace(state, unquote(ip), "capclose", s)
        state = %{state | cap_stack: [{:close, s} | state.cap_stack]}
        {state, s, unquote(ip+1)}
      end

      {:code, code} -> quote do
        Xpeg.trace(state, unquote(ip), "code", s)
        state = Xpeg.collect_captures(state)
        func = unquote code
        captures = func.(state.captures)
        state = %{state | captures: captures}
        {state, s, unquote(ip+1)}
      end

      {:fail} -> quote do
        Xpeg.trace(state, unquote(ip), "fail", s)
        case state.back_stack do
          [frame | back_stack] ->
            state = %{state |
              back_stack: back_stack,
              ret_stack: frame.ret_stack,
              cap_stack: frame.cap_stack
            }
            {state, frame.s, frame.ip_back}
          [] ->
            state = %{state | status: :error}
            {state, s, 0}
        end
      end
    end
  end


  defp emit(program) do

    cases = program.instructions
            |> Enum.map(fn {ip, inst} ->
              body = emit_inst(ip, inst)
              {:->, [], [[ip], body] }
            end)

    quote do
      fn state, s, ip ->
        {state, s, ip} = case ip do
          unquote(cases)
        end
        case state.status do
          :running ->
            state.func.(state, s, ip)
          _ ->
            %{state | match_len: Enum.count(state.s) - Enum.count(s)}
        end
      end
    end
    #|> tap(&IO.puts(Macro.to_string(&1)))
  end


  defp link_one(program, rules, name) do
    instructions = rules[name]
    program = %{ program |
      symtab: Map.put(program.symtab, name, Enum.count(program.instructions)),
      instructions: program.instructions ++ instructions
    }
    Enum.reduce(instructions, program, fn inst, program ->
      case inst do
        {:call, callname} ->
          if ! Map.has_key?(rules, callname) do
            raise("XPeg: rule '#{name}' is referencing undefined rule '#{callname}'")
          end
          if ! Map.has_key?(program.symtab, callname) do
            link_one(program, rules, callname)
          else
            program
          end
        _ ->
          program
      end
    end)
  end


  defp link_grammar(grammar) do
    program = %{
      instructions: [],
      symtab: %{}
    }
    program = link_one(program, grammar.rules, grammar.start)
    program = Map.put(program, :instructions, Enum.with_index(program.instructions, fn inst, ip ->
      case inst do
        {:call, name} ->
          {ip, {:call, program.symtab[name]}}
        inst ->
          {ip, inst}
      end
    end))
    program = %{program | instructions: program.instructions ++ [ {:fail, {:fail} }]}
    program
  end


  defmacro peg(start, [{:do, v}]) do
    %{
      start: start,
      rules: Parsepatt.parse(v) |> Map.new
    }
    |> link_grammar
    #|> IO.inspect
    |> emit
  end


  defmacro patt(v) do
    %{
      start: :anon,
      rules: %{ anon: Parsepatt.parse(v) ++ [{:return}]}
    }
    |> link_grammar
    #|> IO.inspect
    |> emit
  end


  def match(func, s) do
    s = String.to_charlist(s)
    %{
      func: func,
      s: s,
      status: :running,
      back_stack: [],
      ret_stack: [],
      cap_stack: [],
      captures: [],
      do_trace: false,
      match_len: 0,
    }
    |> func.(s, 0)
    |> collect_captures()
  end

  def run() do

    p = peg :exp do
      :exp     <- :term   * star(:exp_op)
      :term    <- :factor * star(:term_op)
      :factor  <- :number | "(" * :exp * ")"
      :number  <- cap(+{'0'..'9'}) * fn [v|cs] -> [String.to_integer(v)|cs] end
      :term_op <- cap({'*','/'}) * :factor * fn [b,op,a|cs] -> [{op,a,b}|cs] end
      :exp_op  <- cap({'+','-'}) * :term   * fn [b,op,a|cs] -> [{op,a,b}|cs] end
    end

    match(p, "1+(2-3*4)/5")

  end

end

# set ft=elixir
