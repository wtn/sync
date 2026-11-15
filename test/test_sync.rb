# frozen_string_literal: false
require 'test/unit'
require 'sync'
require 'timeout'

class SyncTest < Test::Unit::TestCase
  class Tester
    include Sync_m
  end

  def test_sync_lock_and_wakeup
    tester = Tester.new

    tester.sync_lock(:EX)

    t = Thread.new { tester.sync_lock(:EX) }

    sleep 0.1 until t.stop?
    t.wakeup
    sleep 0.1 until t.stop?

    assert_equal(tester.sync_waiting.uniq, tester.sync_waiting)
  ensure
    t.kill
    t.join
  end

  def test_sync_upgrade_and_wakeup
    tester = Tester.new
    tester.sync_lock(:SH)

    t = Thread.new do
      tester.sync_lock(:SH)
      tester.sync_lock(:EX)
    end

    sleep 0.1 until t.stop?
    t.wakeup
    sleep 0.1 until t.stop?

    tester.sync_upgrade_waiting.each { |ary|
      assert(!tester.sync_waiting.include?(ary[0]))
    }
    assert_equal(tester.sync_waiting.uniq, tester.sync_waiting)
    assert_equal(tester.sync_waiting, [])
  ensure
    t.kill
    t.join
  end

  def test_unlock_skips_dead_waiters
    tester = Tester.new
    dead = Thread.new {}
    dead.join
    tester.sync_lock(:EX)
    tester.sync_upgrade_waiting.push([dead, 1])
    tester.sync_waiting.push(dead)

    t = Thread.new do
      tester.sync_lock(:EX)
      tester.sync_unlock
      :done
    end
    sleep 0.1 until t.stop?

    assert_nothing_raised { tester.sync_unlock }
    assert_equal(:done, t.join(5) && t.value)
    assert_equal({}, tester.sync_sh_locker)
    assert_equal(:UN, tester.sync_mode)
  ensure
    t.kill
    t.join
  end

  def test_killed_upgrade_waiter
    tester = Tester.new
    tester.sync_lock(:SH)

    t = Thread.new do
      tester.sync_synchronize(:SH) do
        tester.sync_lock(:EX)
      end
    end
    sleep 0.1 until t.stop?
    t.kill
    t.join

    assert_equal([], tester.sync_upgrade_waiting)
    assert_equal([Thread.current], tester.sync_sh_locker.keys)

    assert_nothing_raised { tester.sync_unlock }
    assert_equal(:UN, tester.sync_mode)
    assert_equal(true, tester.sync_try_lock(:EX))
  end

  def test_interrupted_upgrade_waiter_keeps_shared_lock
    tester = Tester.new
    tester.sync_lock(:SH)

    t = Thread.new do
      tester.sync_synchronize(:SH) do
        tester.sync_lock(:EX)
      end
    end
    t.report_on_exception = false
    sleep 0.1 until t.stop?
    t.raise(ArgumentError, "interrupt")

    assert_raise(ArgumentError) { t.join }
    assert_equal([], tester.sync_upgrade_waiting)
    assert_equal([Thread.current], tester.sync_sh_locker.keys)

    tester.sync_unlock
    assert_equal(:UN, tester.sync_mode)
  end

  def test_interrupted_upgrade_waiter_under_other_exclusive
    tester = Tester.new
    tester.sync_lock(:SH)

    t = Thread.new do
      tester.sync_synchronize(:SH) do
        tester.sync_lock(:EX)
      end
    end
    t.report_on_exception = false
    sleep 0.1 until t.stop?
    assert_equal(true, tester.sync_try_lock(:EX))
    t.raise(ArgumentError, "interrupt")

    assert_raise(ArgumentError) { t.join }
    assert_equal(true, tester.sync_exclusive?)

    tester.sync_unlock
    assert_equal(:SH, tester.sync_mode)
    tester.sync_unlock
    assert_equal(:UN, tester.sync_mode)
    assert_equal({}, tester.sync_sh_locker)
  end

  def test_sync_lock_and_raise
    tester= Tester.new
    tester.sync_lock(:EX)

    t = Thread.new {
      assert_raise(RuntimeError) {
        tester.sync_lock(:EX)
      }
    }

    sleep 0.1 until t.stop?
    sleep 1 if defined?(RubyVM::JIT) && RubyVM::JIT.enabled? # t.stop? behaves unexpectedly with --jit-wait
    t.raise
    t.join

    assert_equal(tester.sync_waiting.uniq, tester.sync_waiting)
    assert_equal(tester.sync_waiting, [])
  end
end
