-- | Formless is a renderless component to help you build forms in Halogen.
-- | It expects that you have already written a form spec and validation and
-- | you simply need a component to run it on your behalf.

module Formless
  ( Query(..)
  , Query'(..)
  , StateStore(..)
  , Component(..)
  , HTML(..)
  , HTML'(..)
  , DSL(..)
  , State(..)
  , PublicState(..)
  , Input(..)
  , Input'(..)
  , Message(..)
  , Message'(..)
  , StateRow(..)
  , InternalState(..)
  , ValidStatus(..)
  , component
  , module Formless.Spec
  , module Formless.Class.Initial
  , module Formless.Validation
  , send'
  , modify
  , modify_
  , modifyValidate
  , modifyValidate_
  , validate
  , validate_
  , reset
  , reset_
  )
  where

import Formless.Spec
import Formless.Validation
import Prelude

import Control.Comonad (extract)
import Control.Comonad.Store (Store, store)
import Data.Const (Const)
import Data.Eq (class EqRecord)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Maybe (Maybe(..))
import Data.Monoid.Additive (Additive)
import Data.Newtype (class Newtype, over, unwrap, wrap)
import Data.Symbol (class IsSymbol, SProxy(..))
import Data.Traversable (traverse, traverse_)
import Data.Variant (Variant, inj)
import Data.Variant.Internal (VariantRep(..), unsafeGet)
import Formless.Class.Initial (class Initial, initial)
import Formless.Transform.Record
import Halogen as H
import Halogen.Component.ChildPath (ChildPath, injQuery, injSlot)
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Heterogeneous.Folding (class HFoldlWithIndex)
import Heterogeneous.Mapping (class HMap, class HMapWithIndex)
import Prim.Row as Row
import Prim.RowList as RL
import Record as Record
import Record.Builder (Builder)
import Renderless.State (getState, modifyState, modifyState_, modifyStore_)
import Unsafe.Coerce (unsafeCoerce)

data Query pq cq cs form out m a
  = Modify (form Variant InputField) a
  | Validate (form Variant U) a
  | ModifyValidate (form Variant InputField) a
  | Reset (form Variant InputField) a
  | ResetAll a
  | ValidateAll a
  | Submit a
  | SubmitReply (Maybe out -> a)
  | Reply (PublicState form -> a)
  | Send cs (cq Unit) a
  | SyncFormData a
  | Raise (pq Unit) a
  | ReplaceInputs (form Record InputField) a
  | Receive (Input pq cq cs form out m) a
  | AndThen (Query pq cq cs form out m Unit) (Query pq cq cs form out m Unit) a

-- | The overall component state type, which contains the local state type
-- | and also the render function
type StateStore pq cq cs form out m =
  Store (State form out m) (HTML pq cq cs form out m)

-- | The component type
type Component pq cq cs form out m
  = H.Component
      HH.HTML
      (Query pq cq cs form out m)
      (Input pq cq cs form out m)
      (Message pq form out)
      m

-- | The component's HTML type, the result of the render function.
type HTML pq cq cs form out m
  = H.ParentHTML (Query pq cq cs form out m) cq cs m

-- | The component's DSL type, the result of the eval function.
type DSL pq cq cs form out m
  = H.ParentDSL
      (StateStore pq cq cs form out m)
      (Query pq cq cs form out m)
      cq
      cs
      (Message pq form out)
      m

-- | The component local state
type State form out m = Record (StateRow form (internal :: InternalState form out m))

-- | The component's public state
type PublicState form = Record (StateRow form ())

-- | The component's public state
type StateRow form r =
  ( validity :: ValidStatus
  , dirty :: Boolean
  , submitting :: Boolean
  , errors :: Int
  , submitAttempts :: Int
  , form :: form Record FormField
  | r
  )

-- | A newtype to make easier type errors for end users to
-- | read by hiding internal fields
newtype InternalState form out m = InternalState
  { initialInputs :: form Record InputField
  , formResult :: Maybe out
  , allTouched :: Boolean
  , submitter :: form Record OutputField -> m out
  , validators :: form Record (Validation form m)
  }
derive instance newtypeInternalState :: Newtype (InternalState form out m) _

-- | A type to represent validation status
data ValidStatus
  = Invalid
  | Incomplete
  | Valid
derive instance genericValidStatus :: Generic ValidStatus _
derive instance eqValidStatus :: Eq ValidStatus
derive instance ordValidStatus :: Ord ValidStatus
instance showValidStatus :: Show ValidStatus where
  show = genericShow

-- | The component's input type
type Input pq cq cs form out m =
  { submitter :: form Record OutputField -> m out
  , inputs :: form Record InputField
  , validators :: form Record (Validation form m)
  , render :: State form out m -> HTML pq cq cs form out m
  }

-- | The component tries to require as few messages to be handled as possible. You
-- | can always use the *Reply variants of queries to perform actions and receive
-- | a result out the other end.
data Message pq form out
  = Submitted out
  | Changed (PublicState form)
  | Emit (pq Unit)

-- | When you are using several different types of child components in Formless
-- | the component needs a child path to be able to pick the right slot to send
-- | a query to.
send' :: ∀ pq cq' cs' cs cq form out m a
  . ChildPath cq cq' cs cs'
 -> cs
 -> cq Unit
 -> a
 -> Query pq cq' cs' form out m a
send' path p q = Send (injSlot path p) (injQuery path q)

-- | Simple types

-- | A simple query type when you have no child slots in use
type Query' form out m = Query (Const Void) (Const Void) Void form out m

-- | A simple HTML type when the component does not need embedding
type HTML' form out m = H.ParentHTML (Query' form out m) (Const Void) Void m

-- | A simple Message type when the component does not need embedding
type Message' form out = Message (Const Void) form out

-- | A simple Input type when the component does not need embedding
type Input' form out m = Input (Const Void) (Const Void) Void form out m


-- | The component itself
component
  :: ∀ pq cq cs form out m is ixs ivs fs us vs gs
   . Ord cs
  => Monad m
  => RL.RowToList is ixs
  => EqRecord ixs is
  => HMap InputFieldToFormField { | is } { | fs }
  => HMapWithIndex (ReplaceInput is) { | fs } { | fs }
  => Newtype (form Record InputField) { | is }
  => Newtype (form Variant InputField) (Variant ivs)
  => Newtype (form Record FormField) { | fs }
  => Newtype (form Record (Validation form m)) { | vs }
  => Newtype (form Variant U) (Variant us)
  => Component pq cq cs form out m
component =
  H.parentComponent
    { initialState
    , render: extract
    , eval
    , receiver: HE.input Receive
    }
  where

  initialState :: Input pq cq cs form out m -> StateStore pq cq cs form out m
  initialState { inputs, validators, render, submitter } = store render $
    { validity: Incomplete
    , dirty: false
    , errors: 0
    , submitAttempts: 0
    , submitting: false
    , form: wrap $ inputFieldsToFormFields $ unwrap inputs
    , internal: InternalState
      { formResult: Nothing
      , allTouched: false
      , initialInputs: inputs
      , submitter
      , validators
      }
    }

  eval :: Query pq cq cs form out m ~> DSL pq cq cs form out m
  eval = case _ of
    Modify variant a -> do
      modifyState_ \st -> st { form = unsafeSetInputVariant variant st.form }
      eval $ SyncFormData a

    Validate variant a -> do
      st <- getState
      form <- H.lift $ unsafeRunValidationVariant variant (unwrap st.internal).validators st.form
      modifyState_ _ { form = form }
      eval $ SyncFormData a

    ModifyValidate variant a -> do
      void $ eval $ Modify variant a
      void $ eval $ Validate (unsafeCoerce variant :: form Variant U) a
      eval $ SyncFormData a

    Reset variant a -> do
      modifyState_ \st -> st
        { form = wrap $ replaceFormFieldInputs (unwrap (unwrap st.internal).initialInputs) (unwrap st.form)
        , internal = over InternalState (_ { allTouched = false }) st.internal
        }
      eval $ SyncFormData a

    ValidateAll a -> do
			-- TODO
      --  st <- getState
      --  form <- H.lift $ applyValidation st.form (unwrap (unwrap st.internal).validators)
      --  modifyState_ _ { form = wrap form }
      eval $ SyncFormData a

    -- A query to sync the overall state of the form after an individual field change
    -- or overall validation.
    SyncFormData a -> do
      -- TODO
      --  modifyState_ \st -> st
      --    { errors = ?countErrors st.form
      --      -- Dirty state is computed by checking equality of original input fields
      --      -- vs. current ones. This relies on input fields passed by the user having
      --      -- equality defined.
      --    , dirty = not $ (==)
      --        (unwrap (?formFieldsToInputFields st.form))
      --        (unwrap (unwrap st.internal).initialInputs)
      --    }

      st <- getState
      -- Need to verify the validity status of the form.
      new <- case (unwrap st.internal).allTouched of
        true -> modifyState _
          { validity = if not (st.errors == 0) then Invalid else Valid }

        -- If not all fields are touched, then we need to quickly sync the form state
        -- to verify this is actually the case.
        _ -> case ?checkTouched st.form of

          -- The sync revealed all fields really have been touched
          true -> modifyState _
            { validity = if not (st.errors == 0) then Invalid else Valid
            , internal = over InternalState (_ { allTouched = true }) st.internal
            }

          -- The sync revealed that not all fields have been touched
          _ -> modifyState _
            { validity = Incomplete }

      H.raise $ Changed $ getPublicState new
      pure a

    -- Submit, also raising a message to the user
    Submit a -> a <$ do
      st <- runSubmit
      traverse_ (H.raise <<< Submitted) st

    -- Submit, without raising a message, but returning the result directly
    SubmitReply reply -> do
       st <- runSubmit
       pure $ reply st

    -- | Should completely reset the form to its initial state
    ResetAll a -> do
      new <- modifyState \st -> st
        { validity = Incomplete
        , dirty = false
        , errors = 0
        , submitAttempts = 0
        , form = ?replaceFormFieldInputs (unwrap st.internal).initialInputs st.form
        , internal = over InternalState (_
            { formResult = Nothing
            , allTouched = false
            }
          ) st.internal
        }
      H.raise $ Changed $ getPublicState new
      pure a

    Reply reply -> do
      st <- getState
      pure $ reply $ getPublicState st

    -- Only allows actions; always returns nothing. In Halogen v5.0.0 branch this does return
    -- requests as expected in a Halogen component.
    Send cs cq a -> H.query cs cq $> a

    Raise query a -> do
      H.raise (Emit query)
      pure a

    ReplaceInputs formInputs a -> do
      st <- getState
      new <- modifyState _
        { validity = Incomplete
        , dirty = false
        , errors = 0
        , submitAttempts = 0
        , submitting = false
        , form = ?replaceInput formInputs st.form
        , internal = over InternalState
          (_ { formResult = Nothing
             , allTouched = false
             , initialInputs = formInputs
             }) st.internal
        }
      H.raise $ Changed $ getPublicState new
      pure a

    Receive { render, validators, submitter } a -> do
      let applyOver = over InternalState (_ { validators = validators, submitter = submitter })
      modifyStore_ render (\st -> st { internal = applyOver st.internal })
      pure a

    AndThen q1 q2 a -> do
      _ <- eval q1
      _ <- eval q2
      pure a

  -- Remove internal fields and return the public state
  getPublicState :: State form out m -> PublicState form
  getPublicState = Record.delete (SProxy :: SProxy "internal")

  -- Run submission without raising messages or replies
  runSubmit :: DSL pq cq cs form out m (Maybe out)
  runSubmit = do
    init <- modifyState \st -> st
      { submitAttempts = st.submitAttempts + 1
      , submitting = true
      }

    -- For performance purposes, avoid running this if possible
    let internal = unwrap init.internal
    when (not internal.allTouched) do
      pure unit
      -- TODO
      --  modifyState_ _
      --   { form = ?setTouched (over FormField (_ { touched = true })) init.form
      --   , internal = over InternalState (_ { allTouched = true }) init.internal
      --   }

    -- Necessary to validate after fields are touched, but before parsing
    _ <- eval $ ValidateAll unit

    -- For performance purposes, only attempt to submit if the form is valid
    validated <- getState
    when (validated.validity == Valid) do
      output <- H.lift $ ?sequenceRecord (?toMaybeOut validated.form)
      modifyState_ _
        { internal = over InternalState (_ { formResult = output }) validated.internal }

    -- Ensure the form is no longer marked submitting
    result <- modifyState \st -> st { submitting = false }
    pure (unwrap result.internal).formResult


----------
-- Component helper functions for variants

-- | A helper to create the correct `Modify` query for Formless given a label and
-- | an input value
modify
  :: ∀ pq cq cs form inputs out m sym t0 e i o a
   . IsSymbol sym
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> i
  -> a
  -> Query pq cq cs form out m a
modify sym i = Modify (wrap (inj sym (wrap i)))

-- | A helper to create the correct `Modify` query for Formless given a label and
-- | an input value, as an action
modify_
  :: ∀ pq cq cs form inputs out m sym t0 e i o
   . IsSymbol sym
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> i
  -> Query pq cq cs form out m Unit
modify_ sym i = Modify (wrap (inj sym (wrap i))) unit

-- | A helper to create the correct `ModifyValidate` query for Formless given a
-- | label and an input value
modifyValidate
  :: ∀ pq cq cs form inputs out m sym t0 e i o a
   . IsSymbol sym
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> i
  -> a
  -> Query pq cq cs form out m a
modifyValidate sym i = ModifyValidate (wrap (inj sym (wrap i)))

-- | A helper to create the correct `ModifyValidate` query for Formless given a
-- | label and an input value, as an action
modifyValidate_
  :: ∀ pq cq cs form inputs out m sym t0 e i o
   . IsSymbol sym
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> i
  -> Query pq cq cs form out m Unit
modifyValidate_ sym i = ModifyValidate (wrap (inj sym (wrap i))) unit

-- | A helper to create the correct `Reset` query for Formless given a label
reset
  :: ∀ pq cq cs form inputs out m sym a t0 e i o
   . IsSymbol sym
  => Initial i
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> a
  -> Query pq cq cs form out m a
reset sym = Reset (wrap (inj sym (wrap initial)))

-- | A helper to create the correct `Reset` query for Formless given a label,
-- | as an action.
reset_
  :: ∀ pq cq cs form inputs out m sym t0 e i o
   . IsSymbol sym
  => Initial i
  => Newtype (form Variant InputField) (Variant inputs)
  => Row.Cons sym (InputField e i o) t0 inputs
  => SProxy sym
  -> Query pq cq cs form out m Unit
reset_ sym = Reset (wrap (inj sym (wrap initial))) unit

-- | A helper to create the correct `Validate` query for Formless, given
-- | a label
validate
  :: ∀ pq cq cs form us out m sym a t0 e i o
   . IsSymbol sym
  => Newtype (form Variant U) (Variant us)
  => Row.Cons sym (U e i o) t0 us
  => SProxy sym
  -> a
  -> Query pq cq cs form out m a
validate sym = Validate (wrap (inj sym U))

-- | A helper to create the correct `Validate` query for Formless given
-- | a label, as an action
validate_
  :: ∀ pq cq cs form us out m sym t0 e i o
   . IsSymbol sym
  => Newtype (form Variant U) (Variant us)
  => Row.Cons sym (U e i o) t0 us
  => SProxy sym
  -> Query pq cq cs form out m Unit
validate_ sym = Validate (wrap (inj sym U)) unit
