{-# LINE 1 "Data/Text/ICU/Internal.hsc" #-}
{-# LANGUAGE EmptyDataDecls, ForeignFunctionInterface, GeneralizedNewtypeDeriving, TupleSections #-}

module Data.Text.ICU.Internal
    (
      LocaleName(..)
    , UBool
    , UChar
    , UChar32
    , UCharIterator
    , CharIterator(..)
    , UText, UTextPtr
    , asBool
    , asOrdering
    , withCharIterator
    , withLocaleName
    , withName
    , useAsUCharPtr, fromUCharPtr, I16, asUCharForeignPtr
    , asUTextPtr, withUTextPtr, withUTextPtrText, emptyUTextPtr, utextPtrLength
    , TextI, takeWord, dropWord, lengthWord
    , newICUPtr
    ) where



import Control.Exception (mask_)
import Control.DeepSeq (NFData(..))
import Data.ByteString.Internal (ByteString(..))
import Data.Int (Int8, Int32, Int64)
import Data.String (IsString(..))
import Data.Text (Text, empty)
import Data.Text.Encoding (decodeUtf8)
import Data.Text.Foreign (useAsPtr, asForeignPtr, fromPtr)

{-# LINE 39 "Data/Text/ICU/Internal.hsc" #-}
import Data.Text.Foreign (I16, dropWord16, takeWord16, lengthWord16)

{-# LINE 41 "Data/Text/ICU/Internal.hsc" #-}
import Data.Word (Word8, Word16, Word32)
import Foreign.C.String (CString, withCString)
import Foreign.ForeignPtr (withForeignPtr, ForeignPtr, newForeignPtr, FinalizerPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr, FunPtr)
import Data.Text.ICU.Error.Internal (UErrorCode)
import System.IO.Unsafe (unsafePerformIO)

-- | A type that supports efficient iteration over Unicode characters.
--
-- As an example of where this may be useful, a function using this
-- type may be able to iterate over a UTF-8 'ByteString' directly,
-- rather than first copying and converting it to an intermediate
-- form.  This type also allows e.g. comparison between 'Text' and
-- 'ByteString', with minimal overhead.
data CharIterator = CIText !Text
                  | CIUTF8 !ByteString

instance Show CharIterator where
    show (CIText t)  = show t
    show (CIUTF8 bs) = show (decodeUtf8 bs)

data UCharIterator

-- | Temporarily allocate a 'UCharIterator' and use it with the
-- contents of the to-be-iterated-over string.
withCharIterator :: CharIterator -> (Ptr UCharIterator -> IO a) -> IO a
withCharIterator (CIUTF8 (PS fp _ l)) act =
    allocaBytes ((112)) $ \i -> withForeignPtr fp $ \p ->
{-# LINE 71 "Data/Text/ICU/Internal.hsc" #-}
    uiter_setUTF8 i p (fromIntegral l) >> act i
withCharIterator (CIText t) act =
    allocaBytes ((112)) $ \i -> useAsPtr t $ \p l ->
{-# LINE 74 "Data/Text/ICU/Internal.hsc" #-}

{-# LINE 77 "Data/Text/ICU/Internal.hsc" #-}
    uiter_setString i p (fromIntegral l) >> act i

{-# LINE 79 "Data/Text/ICU/Internal.hsc" #-}

type UBool   = Int8
type UChar   = Word16
type UChar32 = Word32

asBool :: Integral a => a -> Bool
{-# INLINE asBool #-}
asBool = (/=0)

asOrdering :: Integral a => a -> Ordering
{-# INLINE asOrdering #-}
asOrdering i
    | i < 0     = LT
    | i == 0    = EQ
    | otherwise = GT

withName :: String -> (CString -> IO a) -> IO a
withName name act
    | null name = act nullPtr
    | otherwise = withCString name act

-- | The name of a locale.
data LocaleName = Root
                -- ^ The root locale.  For a description of resource bundles
                -- and the root resource, see
                -- <http://userguide.icu-project.org/locale/resources>.
                | Locale String -- ^ A specific locale.
                | Current       -- ^ The program's current locale.
                  deriving (Eq, Ord, Read, Show)

instance NFData LocaleName where
    rnf Root       = ()
    rnf (Locale l) = rnf l
    rnf Current    = ()

instance IsString LocaleName where
    fromString = Locale

withLocaleName :: LocaleName -> (CString -> IO a) -> IO a
withLocaleName Current act = act nullPtr
withLocaleName Root act = withCString "" act
withLocaleName (Locale n) act = withCString n act


{-# LINE 123 "Data/Text/ICU/Internal.hsc" #-}
foreign import ccall unsafe "hs_text_icu.h __hs_uiter_setString" uiter_setString
    :: Ptr UCharIterator -> Ptr UChar -> Int32 -> IO ()

{-# LINE 126 "Data/Text/ICU/Internal.hsc" #-}

foreign import ccall unsafe "hs_text_icu.h __hs_uiter_setUTF8" uiter_setUTF8
    :: Ptr UCharIterator -> Ptr Word8 -> Int32 -> IO ()


data UText

-- | Pointer to UText which also keeps pointer to source text so it won't be
-- garbage collected.
data UTextPtr
    = UTextPtr
      { utextPtr :: ForeignPtr UText
      , utextPtrText :: ForeignPtr TextChar
      , utextPtrLength :: TextI
      }

emptyUTextPtr :: UTextPtr
emptyUTextPtr = unsafePerformIO $ asUTextPtr empty
{-# NOINLINE emptyUTextPtr #-}

withUTextPtr :: UTextPtr -> (Ptr UText -> IO a) -> IO a
withUTextPtr = withForeignPtr . utextPtr

withUTextPtrText :: UTextPtr -> (Ptr TextChar -> IO a) -> IO a
withUTextPtrText = withForeignPtr . utextPtrText

-- | Returns UTF-8 UText for text >= 2.0 or UTF-16 UText for previous versions.
asUTextPtr :: Text -> IO UTextPtr
asUTextPtr t = do
    (fp,l) <- asForeignPtr t
    with 0 $ \ e -> withForeignPtr fp $ \ p ->
      newICUPtr (\ ut -> UTextPtr ut fp l) utext_close $

{-# LINE 161 "Data/Text/ICU/Internal.hsc" #-}
        utext_openUChars

{-# LINE 163 "Data/Text/ICU/Internal.hsc" #-}
          nullPtr p (fromIntegral l) e

foreign import ccall unsafe "hs_text_icu.h &__hs_utext_close" utext_close
    :: FunPtr (Ptr UText -> IO ())

useAsUCharPtr :: Text -> (Ptr UChar -> I16 -> IO a) -> IO a
asUCharForeignPtr :: Text -> IO (ForeignPtr UChar, I16)
fromUCharPtr :: Ptr UChar -> I16 -> IO Text

dropWord, takeWord :: TextI -> Text -> Text
lengthWord :: Text -> Int


{-# LINE 224 "Data/Text/ICU/Internal.hsc" #-}

type TextChar = UChar
type TextI = I16

-- text < 2.0 has UChar as internal representation.
useAsUCharPtr = useAsPtr
asUCharForeignPtr = asForeignPtr
fromUCharPtr = fromPtr

dropWord = dropWord16
takeWord = takeWord16
lengthWord = lengthWord16

foreign import ccall unsafe "hs_text_icu.h __hs_utext_openUChars" utext_openUChars
    :: Ptr UText -> Ptr UChar -> Int64 -> Ptr UErrorCode -> IO (Ptr UText)


{-# LINE 241 "Data/Text/ICU/Internal.hsc" #-}

-- | Allocate new ICU data structure (usually via @*_open@ call),
-- add finalizer (@*_close@ call) and wrap resulting 'ForeignPtr'.
--
-- Exceptions are masked since the memory leak is possible if any
-- asynchronous exception (such as a timeout) is raised between
-- allocating C data and 'newForeignPtr' call.
newICUPtr :: (ForeignPtr a -> i) -> FinalizerPtr a -> IO (Ptr a) -> IO i
newICUPtr wrap close open = fmap wrap $ mask_ $ newForeignPtr close =<< open
