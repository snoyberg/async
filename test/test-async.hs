{-# LANGUAGE ScopedTypeVariables,DeriveDataTypeable #-}
module Main where

import Test.Framework (defaultMain, testGroup)
import Test.Framework.Providers.HUnit

import Test.HUnit

import Control.Concurrent.Async
import Control.Exception
import Data.IORef
import Data.Typeable
import Control.Concurrent
import Control.Monad
import Data.List (sort)
import Data.Maybe

import Prelude hiding (catch)

main = defaultMain tests

tests = [
    testCase "async_wait"        async_wait
  , testCase "async_waitCatch"   async_waitCatch
  , testCase "async_exwait"      async_exwait
  , testCase "async_exwaitCatch" async_exwaitCatch
  , testCase "withasync_waitCatch" withasync_waitCatch
  , testCase "withasync_wait2"   withasync_wait2
  , testGroup "async_cancel_rep" $
      replicate 1000 $
         testCase "async_cancel"       async_cancel
  , testCase "async_poll"        async_poll
  , testCase "async_poll2"       async_poll2
  , testCase "withasync_waitCatch_blocked" withasync_waitCatch_blocked
  , testGroup "children surviving too long"
      [ testCase "concurrently+success" concurrently_success
      , testCase "concurrently+failure" concurrently_failure
      , testCase "race+success" race_success
      , testCase "race+failure" race_failure
      , testCase "cancel" cancel_survive
      , testCase "withAsync" withasync_survive
      ]
  , testCase "concurrently_" case_concurrently_
  , testCase "replicateConcurrently_" case_replicateConcurrently
  , testCase "replicateConcurrently" case_replicateConcurrently_
 ]

value = 42 :: Int

data TestException = TestException deriving (Eq,Show,Typeable)
instance Exception TestException

async_waitCatch :: Assertion
async_waitCatch = do
  a <- async (return value)
  r <- waitCatch a
  case r of
    Left _  -> assertFailure ""
    Right e -> e @?= value

async_wait :: Assertion
async_wait = do
  a <- async (return value)
  r <- wait a
  assertEqual "async_wait" r value

async_exwaitCatch :: Assertion
async_exwaitCatch = do
  a <- async (throwIO TestException)
  r <- waitCatch a
  case r of
    Left e  -> fromException e @?= Just TestException
    Right _ -> assertFailure ""

async_exwait :: Assertion
async_exwait = do
  a <- async (throwIO TestException)
  (wait a >> assertFailure "") `catch` \e -> e @?= TestException

withasync_waitCatch :: Assertion
withasync_waitCatch = do
  withAsync (return value) $ \a -> do
    r <- waitCatch a
    case r of
      Left _  -> assertFailure ""
      Right e -> e @?= value

withasync_wait2 :: Assertion
withasync_wait2 = do
  a <- withAsync (threadDelay 1000000) $ return
  r <- waitCatch a
  case r of
    Left e  -> fromException e @?= Just ThreadKilled
    Right _ -> assertFailure ""

async_cancel :: Assertion
async_cancel = do
  a <- async (return value)
  cancelWith a TestException
  r <- waitCatch a
  case r of
    Left e -> fromException e @?= Just TestException
    Right r -> r @?= value

async_poll :: Assertion
async_poll = do
  a <- async (threadDelay 1000000)
  r <- poll a
  when (isJust r) $ assertFailure ""
  r <- poll a   -- poll twice, just to check we don't deadlock
  when (isJust r) $ assertFailure ""

async_poll2 :: Assertion
async_poll2 = do
  a <- async (return value)
  wait a
  r <- poll a
  when (isNothing r) $ assertFailure ""
  r <- poll a   -- poll twice, just to check we don't deadlock
  when (isNothing r) $ assertFailure ""

withasync_waitCatch_blocked :: Assertion
withasync_waitCatch_blocked = do
  r <- withAsync (newEmptyMVar >>= takeMVar) waitCatch
  case r of
    Left e ->
        case fromException e of
            Just BlockedIndefinitelyOnMVar -> return ()
            Nothing -> assertFailure $ show e
    Right () -> assertFailure ""

concurrently_success :: Assertion
concurrently_success = do
  finalRes <- newIORef "never filled"
  baton <- newEmptyMVar
  let quick = return ()
      slow = threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "slow"
        putMVar baton ()
  _ <- concurrently quick slow
  writeIORef finalRes "parent"
  takeMVar baton
  res <- readIORef finalRes
  res @?= "parent"

concurrently_failure :: Assertion
concurrently_failure = do
  finalRes <- newIORef "never filled"
  let quick = error "a quick death"
      slow = threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "slow"
  _ :: Either SomeException ((), ()) <- try (concurrently quick slow)
  writeIORef finalRes "parent"
  threadDelay 1000000 -- not using the baton, can lead to deadlock detection
  res <- readIORef finalRes
  res @?= "parent"

race_success :: Assertion
race_success = do
  finalRes <- newIORef "never filled"
  let quick = return ()
      slow = threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "slow"
  race_ quick slow
  writeIORef finalRes "parent"
  threadDelay 1000000 -- not using the baton, can lead to deadlock detection
  res <- readIORef finalRes
  res @?= "parent"

race_failure :: Assertion
race_failure = do
  finalRes <- newIORef "never filled"
  baton <- newEmptyMVar
  let quick = error "a quick death"
      slow = threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "slow"
        putMVar baton ()
  _ :: Either SomeException () <- try (race_ quick slow)
  writeIORef finalRes "parent"
  takeMVar baton
  res <- readIORef finalRes
  res @?= "parent"

cancel_survive :: Assertion
cancel_survive = do
  finalRes <- newIORef "never filled"
  a <- async $ threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "child"
  cancel a
  writeIORef finalRes "parent"
  threadDelay 1000000 -- not using the baton, can lead to deadlock detection
  res <- readIORef finalRes
  res @?= "parent"

withasync_survive :: Assertion
withasync_survive = do
  finalRes <- newIORef "never filled"
  let child = threadDelay 10000 `finally` do
        threadDelay 10000
        writeIORef finalRes "child"
  withAsync child (\_ -> return ())
  writeIORef finalRes "parent"
  threadDelay 1000000 -- not using the baton, can lead to deadlock detection
  res <- readIORef finalRes
  res @?= "parent"

case_concurrently_ :: Assertion
case_concurrently_ = do
  ref <- newIORef 0
  () <- concurrently_
    (atomicModifyIORef ref (\x -> (x + 1, True)))
    (atomicModifyIORef ref (\x -> (x + 2, 'x')))
  res <- readIORef ref
  res @?= 3

case_replicateConcurrently :: Assertion
case_replicateConcurrently = do
  ref <- newIORef 0
  let action = atomicModifyIORef ref (\x -> (x + 1, x + 1))
  resList <- replicateConcurrently 100 action
  resVal <- readIORef ref
  resVal @?= 100
  sort resList @?= [1..100]

case_replicateConcurrently_ :: Assertion
case_replicateConcurrently_ = do
  ref <- newIORef 0
  let action = atomicModifyIORef ref (\x -> (x + 1, x + 1))
  () <- replicateConcurrently_ 100 action
  resVal <- readIORef ref
  resVal @?= 100
