defmodule Skein.StdlibCollectionsTest do
  @moduledoc "Tests for List, Map, Set stdlib modules (1b + 1c)"
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Compiler

  defp compile!(source) do
    case Compiler.compile_string(source) do
      {:module, mod} -> mod
      {:error, errors} -> flunk("Compilation failed: #{inspect(errors)}")
    end
  end

  # ---------------------------------------------------------------
  # List stdlib
  # ---------------------------------------------------------------
  describe "List.length" do
    test "returns length of a list" do
      mod =
        compile!("""
        module ListLen {
          fn len(items: List[Int]) -> Int {
            List.length(items)
          }
        }
        """)

      assert mod.len([1, 2, 3]) == 3
      assert mod.len([]) == 0
    end
  end

  describe "List.reverse" do
    test "reverses a list" do
      mod =
        compile!("""
        module ListRev {
          fn rev(items: List[Int]) -> List[Int] {
            List.reverse(items)
          }
        }
        """)

      assert mod.rev([1, 2, 3]) == [3, 2, 1]
      assert mod.rev([]) == []
    end
  end

  describe "List.sort" do
    test "sorts a list" do
      mod =
        compile!("""
        module ListSort {
          fn sorted(items: List[Int]) -> List[Int] {
            List.sort(items)
          }
        }
        """)

      assert mod.sorted([3, 1, 2]) == [1, 2, 3]
      assert mod.sorted([]) == []
    end
  end

  describe "List.first and List.last" do
    test "returns Option for first/last" do
      mod =
        compile!("""
        module ListFirstLast {
          fn fst(items: List[Int]) -> Option[Int] {
            List.first(items)
          }
          fn lst(items: List[Int]) -> Option[Int] {
            List.last(items)
          }
        }
        """)

      assert mod.fst([1, 2, 3]) == {:some, 1}
      assert mod.lst([1, 2, 3]) == {:some, 3}
      assert mod.fst([]) == :none
      assert mod.lst([]) == :none
    end
  end

  describe "List.head and List.tail" do
    test "head returns Option, tail returns list" do
      mod =
        compile!("""
        module ListHeadTail {
          fn hd(items: List[Int]) -> Option[Int] {
            List.head(items)
          }
          fn tl(items: List[Int]) -> List[Int] {
            List.tail(items)
          }
        }
        """)

      assert mod.hd([1, 2, 3]) == {:some, 1}
      assert mod.tl([1, 2, 3]) == [2, 3]
      assert mod.hd([]) == :none
      assert mod.tl([]) == []
    end
  end

  describe "List.take and List.drop" do
    test "takes and drops elements" do
      mod =
        compile!("""
        module ListTakeDrop {
          fn tk(items: List[Int], n: Int) -> List[Int] {
            List.take(items, n)
          }
          fn dp(items: List[Int], n: Int) -> List[Int] {
            List.drop(items, n)
          }
        }
        """)

      assert mod.tk([1, 2, 3, 4], 2) == [1, 2]
      assert mod.dp([1, 2, 3, 4], 2) == [3, 4]
    end
  end

  describe "List.flatten" do
    test "flattens nested lists" do
      mod =
        compile!("""
        module ListFlatten {
          fn flat(items: List[List[Int]]) -> List[Int] {
            List.flatten(items)
          }
        }
        """)

      assert mod.flat([[1, 2], [3, 4]]) == [1, 2, 3, 4]
      assert mod.flat([]) == []
    end
  end

  describe "List.concat" do
    test "concatenates two lists" do
      mod =
        compile!("""
        module ListConcat {
          fn join(a: List[Int], b: List[Int]) -> List[Int] {
            List.concat(a, b)
          }
        }
        """)

      assert mod.join([1, 2], [3, 4]) == [1, 2, 3, 4]
    end
  end

  describe "List.contains" do
    test "checks membership" do
      mod =
        compile!("""
        module ListContains {
          fn has(items: List[Int], item: Int) -> Bool {
            List.contains(items, item)
          }
        }
        """)

      assert mod.has([1, 2, 3], 2) == true
      assert mod.has([1, 2, 3], 4) == false
    end
  end

  describe "List.uniq" do
    test "removes duplicates" do
      mod =
        compile!("""
        module ListUniq {
          fn unique(items: List[Int]) -> List[Int] {
            List.uniq(items)
          }
        }
        """)

      assert mod.unique([1, 2, 2, 3, 3, 3]) == [1, 2, 3]
    end
  end

  describe "List.zip" do
    test "zips two lists" do
      mod =
        compile!("""
        module ListZip {
          fn zipped(a: List[Int], b: List[String]) -> List[List[String]] {
            List.zip(a, b)
          }
        }
        """)

      assert mod.zipped([1, 2], ["a", "b"]) == [[1, "a"], [2, "b"]]
    end
  end

  describe "List higher-order functions with FnRef" do
    test "List.map with &fn_ref" do
      mod =
        compile!("""
        module ListMapRef {
          fn double(x: Int) -> Int {
            x * 2
          }
          fn doubled(items: List[Int]) -> List[Int] {
            List.map(items, &double)
          }
        }
        """)

      assert mod.doubled([1, 2, 3]) == [2, 4, 6]
    end

    test "List.filter with &fn_ref" do
      mod =
        compile!("""
        module ListFilterRef {
          fn positive(x: Int) -> Bool {
            x > 0
          }
          fn positives(items: List[Int]) -> List[Int] {
            List.filter(items, &positive)
          }
        }
        """)

      assert mod.positives([1, -2, 3, -4, 5]) == [1, 3, 5]
    end
  end

  # ---------------------------------------------------------------
  # Map stdlib
  # ---------------------------------------------------------------
  describe "Map.get and Map.put" do
    test "get returns Option, put inserts" do
      mod =
        compile!("""
        module MapGetPut {
          fn lookup(m: Map[String, Int], k: String) -> Option[Int] {
            Map.get(m, k)
          }
          fn insert(m: Map[String, Int], k: String, v: Int) -> Map[String, Int] {
            Map.put(m, k, v)
          }
        }
        """)

      assert mod.lookup(%{"a" => 1}, "a") == {:some, 1}
      assert mod.lookup(%{"a" => 1}, "b") == :none
      assert mod.insert(%{}, "x", 42) == %{"x" => 42}
    end
  end

  describe "Map.keys, Map.values, Map.size" do
    test "returns keys, values, and size" do
      mod =
        compile!("""
        module MapInfo {
          fn ks(m: Map[String, Int]) -> List[String] {
            Map.keys(m)
          }
          fn vs(m: Map[String, Int]) -> List[Int] {
            Map.values(m)
          }
          fn sz(m: Map[String, Int]) -> Int {
            Map.size(m)
          }
        }
        """)

      m = %{"a" => 1, "b" => 2}
      assert Enum.sort(mod.ks(m)) == ["a", "b"]
      assert Enum.sort(mod.vs(m)) == [1, 2]
      assert mod.sz(m) == 2
    end
  end

  describe "Map.has and Map.delete" do
    test "checks key presence and deletes" do
      mod =
        compile!("""
        module MapHasDel {
          fn check(m: Map[String, Int], k: String) -> Bool {
            Map.has(m, k)
          }
          fn remove(m: Map[String, Int], k: String) -> Map[String, Int] {
            Map.delete(m, k)
          }
        }
        """)

      assert mod.check(%{"a" => 1}, "a") == true
      assert mod.check(%{"a" => 1}, "b") == false
      assert mod.remove(%{"a" => 1, "b" => 2}, "a") == %{"b" => 2}
    end
  end

  describe "Map.merge" do
    test "merges two maps" do
      mod =
        compile!("""
        module MapMerge {
          fn combined(a: Map[String, Int], b: Map[String, Int]) -> Map[String, Int] {
            Map.merge(a, b)
          }
        }
        """)

      assert mod.combined(%{"a" => 1}, %{"b" => 2}) == %{"a" => 1, "b" => 2}
      assert mod.combined(%{"a" => 1}, %{"a" => 2}) == %{"a" => 2}
    end
  end

  # ---------------------------------------------------------------
  # Set stdlib
  # ---------------------------------------------------------------
  describe "Set.from and Set.to_list" do
    test "creates set from list and back" do
      mod =
        compile!("""
        module SetCreate {
          fn make(items: List[Int]) -> Set[Int] {
            Set.from(items)
          }
          fn to_list(s: Set[Int]) -> List[Int] {
            Set.to_list(s)
          }
        }
        """)

      set = mod.make([1, 2, 2, 3])
      result = mod.to_list(set)
      assert Enum.sort(result) == [1, 2, 3]
    end
  end

  describe "Set.add, Set.remove, Set.contains" do
    test "add, remove, and check membership" do
      mod =
        compile!("""
        module SetOps {
          fn with_item(s: Set[Int], item: Int) -> Set[Int] {
            Set.add(s, item)
          }
          fn without(s: Set[Int], item: Int) -> Set[Int] {
            Set.remove(s, item)
          }
          fn has(s: Set[Int], item: Int) -> Bool {
            Set.contains(s, item)
          }
        }
        """)

      s = MapSet.new([1, 2, 3])
      assert mod.has(s, 2) == true
      assert mod.has(mod.with_item(s, 4), 4) == true
      assert mod.has(mod.without(s, 2), 2) == false
    end
  end

  describe "Set.union, Set.intersection, Set.difference" do
    test "set algebra operations" do
      mod =
        compile!("""
        module SetAlgebra {
          fn unite(a: Set[Int], b: Set[Int]) -> Set[Int] {
            Set.union(a, b)
          }
          fn intersect(a: Set[Int], b: Set[Int]) -> Set[Int] {
            Set.intersection(a, b)
          }
          fn diff(a: Set[Int], b: Set[Int]) -> Set[Int] {
            Set.difference(a, b)
          }
          fn sz(s: Set[Int]) -> Int {
            Set.size(s)
          }
        }
        """)

      a = MapSet.new([1, 2, 3])
      b = MapSet.new([2, 3, 4])
      assert mod.sz(mod.unite(a, b)) == 4
      assert mod.sz(mod.intersect(a, b)) == 2
      assert mod.sz(mod.diff(a, b)) == 1
    end
  end

  # ---------------------------------------------------------------
  # Property tests — collections
  # ---------------------------------------------------------------
  describe "List properties" do
    property "List.reverse(List.reverse(l)) == l" do
      mod =
        compile!("""
        module PropListRev {
          fn rev(items: List[Int]) -> List[Int] {
            List.reverse(items)
          }
        }
        """)

      check all(l <- list_of(integer())) do
        assert mod.rev(mod.rev(l)) == l
      end
    end

    property "List.length is non-negative" do
      mod =
        compile!("""
        module PropListLen {
          fn len(items: List[Int]) -> Int {
            List.length(items)
          }
        }
        """)

      check all(l <- list_of(integer())) do
        assert mod.len(l) >= 0
      end
    end

    property "List.sort is idempotent" do
      mod =
        compile!("""
        module PropListSort {
          fn sorted(items: List[Int]) -> List[Int] {
            List.sort(items)
          }
        }
        """)

      check all(l <- list_of(integer())) do
        assert mod.sorted(mod.sorted(l)) == mod.sorted(l)
      end
    end

    property "List.concat length is sum of lengths" do
      mod =
        compile!("""
        module PropListConcat {
          fn join(a: List[Int], b: List[Int]) -> List[Int] {
            List.concat(a, b)
          }
          fn len(items: List[Int]) -> Int {
            List.length(items)
          }
        }
        """)

      check all(a <- list_of(integer()), b <- list_of(integer())) do
        assert mod.len(mod.join(a, b)) == mod.len(a) + mod.len(b)
      end
    end
  end

  describe "Set properties" do
    property "Set.union is commutative" do
      mod =
        compile!("""
        module PropSetUnion {
          fn unite(a: Set[Int], b: Set[Int]) -> Set[Int] {
            Set.union(a, b)
          }
        }
        """)

      check all(
              a <- list_of(integer(-50..50)),
              b <- list_of(integer(-50..50))
            ) do
        sa = MapSet.new(a)
        sb = MapSet.new(b)
        assert mod.unite(sa, sb) == mod.unite(sb, sa)
      end
    end
  end
end
