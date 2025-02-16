{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ConstraintKinds           #-}

module CSE230.WhilePlus.Eval where

import qualified Data.Map as Map
import           Control.Monad.State
import           Control.Monad.Except
import           Control.Monad.Identity
import           CSE230.WhilePlus.Types

----------------------------------------------------------------------------------------------
-- | A Combined monad that is BOTH 
--    (i) a State monad with state of type WState
--    (ii) an Exception monad with exceptions of type Value 
----------------------------------------------------------------------------------------------
type MonadWhile m = (MonadState WState m, MonadError Value m)

----------------------------------------------------------------------------------------------
-- | `readVar x` returns the value of the variable `x` in the "current store"
----------------------------------------------------------------------------------------------
readVar :: (MonadWhile m) => Variable -> m Value
readVar x = do 
  WS s _ <- get 
  case Map.lookup x s of
    Just v  -> return v
    Nothing -> throwError (IntVal 0)

----------------------------------------------------------------------------------------------
-- | `writeVar x v` updates the value of `x` in the store to `v`
----------------------------------------------------------------------------------------------
writeVar :: (MonadState WState m) => Variable -> Value -> m ()
writeVar x v = do 
  WS s log <- get 
  let s' = Map.insert x v s
  put (WS s' log)

----------------------------------------------------------------------------------------------
-- | `printString msg` adds the message `msg` to the output log
----------------------------------------------------------------------------------------------
printString :: (MonadState WState m) => String -> m ()
printString msg = do
  WS s log <- get
  put (WS s (msg:log))


-- NOTE: See how the types of `writeVar` and `printString` say they CANNOT throw an exception!

----------------------------------------------------------------------------------------------
-- | Requirements & Expected Behavior of New Constructs
----------------------------------------------------------------------------------------------

{- 
  * `Print s e` should log the string `s` followed by whatever `e` evaluates to, 
     for example, `Print "Three: " (IntVal 3)' should "display" 
     i.e. add to the output log, the string  "Three: IntVal 3",

  * `Throw e` evaluates the expression `e` and throws it as an exception

  * `Try s x h` executes the statement `s` and if in the course of
     execution, an exception is thrown, then the exception comes shooting
     up and is assigned to the variable `x` after which the *handler*
     statement `h` is executed.

  In the case of exceptional termination, 

  * the output `wStore` should be the state *at the point where the last exception was thrown, and 

  * the output `wLog` should include all the messages *upto* that point
   
  * Reading an undefined variable should raise an exception carrying the value `IntVal 0`.

  * Division by zero should raise an exception carrying the value `IntVal 1`.

  * A run-time type error (addition of an integer to a boolean, comparison of
    two values of different types) should raise an exception carrying the value
    `IntVal 2`.
-}

checkIntVal :: Value -> Bool
checkIntVal (IntVal _) = True
checkIntVal _ = False

getIntVal :: Value -> Int
getIntVal (IntVal v) = v
getIntVal _ = 0

getBoolVal :: Value -> Bool
getBoolVal (BoolVal v) = v
getBoolVal _ = False

evalE :: (MonadWhile m) => Expression -> m Value
evalE (Var v) = readVar v
evalE (Val v) = return v
evalE (Op bop e1 e2) = do
                          v1 <- evalE e1
                          v2 <- evalE e2
                          case bop of
                            Plus -> if checkIntVal v1 && checkIntVal v2
                                    then return $ IntVal (getIntVal v1 + getIntVal v2)
                                    else throwError (IntVal 2)
                            Minus -> if checkIntVal v1 && checkIntVal v2
                                     then return $ IntVal (getIntVal v1 - getIntVal v2)
                                     else throwError (IntVal 2)
                            Times -> if checkIntVal v1 && checkIntVal v2
                                     then return $ IntVal (getIntVal v1 * getIntVal v2)
                                     else throwError (IntVal 2)
                            Divide -> if checkIntVal v1 && checkIntVal v2
                                      then if getIntVal v2 == 0
                                           then throwError (IntVal 1)
                                           else return $ IntVal (getIntVal v1 `div` getIntVal v2)
                                      else throwError (IntVal 2)
                            Gt -> if checkIntVal v1 && checkIntVal v2
                                  then return $ BoolVal (getIntVal v1 > getIntVal v2)
                                  else throwError (IntVal 2)
                            Ge -> if checkIntVal v1 && checkIntVal v2
                                  then return $ BoolVal (getIntVal v1 >= getIntVal v2)
                                  else throwError (IntVal 2)
                            Lt -> if checkIntVal v1 && checkIntVal v2
                                  then return $ BoolVal (getIntVal v1 < getIntVal v2)
                                  else throwError (IntVal 2)
                            Le -> if checkIntVal v1 && checkIntVal v2
                                  then return $ BoolVal (getIntVal v1 <= getIntVal v2)
                                  else throwError (IntVal 2)

evalS :: (MonadWhile m) => Statement -> m ()
evalS (Assign v expr) = do
                          eValue <- evalE expr
                          writeVar v eValue
evalS (If expr st1 st2) = do
                            bres <- evalE expr
                            if checkIntVal bres
                            then throwError (IntVal 2)
                            else if getBoolVal bres
                                 then evalS st1
                                 else evalS st2
evalS w@(While expr st) = do
                            bres <- evalE expr
                            if checkIntVal bres
                            then throwError (IntVal 2)
                            else do
                                   if getBoolVal bres
                                   then
                                      do
                                        evalS st
                                        evalS w
                                   else return ()
evalS (Sequence st1 st2) = evalS st1 >> evalS st2
evalS (Print s expr) = do
                         v <- evalE expr
                         WS st log <- get
                         put $ WS st ((s ++ show v) : log)
evalS (Throw expr) = do
                       v <- evalE expr
                       throwError v
evalS (Try st1 v st2) = do
                          catchError (evalS st1) (\e -> do
                                                          writeVar v e
                                                          evalS st2)
evalS _ = return ()

--------------------------------------------------------------------------
-- | Next, we will implement a *concrete instance* of a monad `m` that
--   satisfies the constraints of MonadWhile:
--------------------------------------------------------------------------

type Eval a = ExceptT Value (StateT WState Identity) a

--------------------------------------------------------------------------
-- | `runEval` implements a function to *run* the `Eval a` action from 
--   a starting `WState`. You can read the docs for `runState` and `runExceptT` 
--------------------------------------------------------------------------
runEval :: Eval a -> WState -> (Either Value a, WState)
runEval act s = runIdentity (runStateT (runExceptT act) s)

{- | `execute sto stmt` returns a triple `(sto', exn, log)` where
      * `st'` is the output state,
      * `exn` is (Just v) if the program terminates with an "uncaught" exception with Value v 
         or Nothing if the program terminates without an exception.
      * `log` is the log of messages generated by the `Print` statements.

-}
execute :: Store -> Statement -> (Store, Maybe Value, String)
execute sto stmt     = (sto', leftMaybe v, unlines (reverse log))
  where
    (v, WS sto' log) = runEval (evalS stmt) (WS sto [])

leftMaybe :: Either a b -> Maybe a
leftMaybe (Left v)  = Just v
leftMaybe (Right _) = Nothing

------------------------------------------------------------------------------------
-- | When you are done you should see the following behavior 
------------------------------------------------------------------------------------

-- >>> execute initStore test3 == out3 
-- True
