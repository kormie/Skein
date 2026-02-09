defmodule Skein.Runtime.IdempotentPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Skein.Runtime.Idempotent

  setup do
    Idempotent.reset_all()
    :ok
  end

  property "check! returns :ok for any unique key on first call" do
    check all(key <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      Idempotent.reset_all()
      assert :ok = Idempotent.check!(key)
    end
  end

  property "check! throws for any key that was already processed" do
    check all(key <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      Idempotent.reset_all()
      Idempotent.check!(key)
      assert catch_throw(Idempotent.check!(key)) == {:idempotent_skip}
    end
  end

  property "distinct keys never interfere with each other" do
    check all(
            keys <-
              uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 50),
                min_length: 1,
                max_length: 20
              )
          ) do
      Idempotent.reset_all()

      # All first calls should succeed
      for key <- keys do
        assert :ok = Idempotent.check!(key)
      end

      # All second calls should skip
      for key <- keys do
        assert catch_throw(Idempotent.check!(key)) == {:idempotent_skip}
      end
    end
  end

  property "clear allows reprocessing of any key" do
    check all(key <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      Idempotent.reset_all()
      Idempotent.check!(key)
      Idempotent.clear(key)
      assert :ok = Idempotent.check!(key)
    end
  end

  property "processed? returns true iff key has been checked" do
    check all(key <- string(:alphanumeric, min_length: 1, max_length: 100)) do
      Idempotent.reset_all()
      refute Idempotent.processed?(key)
      Idempotent.check!(key)
      assert Idempotent.processed?(key)
    end
  end
end
