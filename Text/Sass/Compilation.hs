-- | Compilation of sass source or sass files.
{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Text.Sass.Compilation
  (
    -- * Compilation
    compileFile
  , compileString
    -- * Error reporting
  , SassError (errorStatus)
  , errorJson
  , errorText
  , errorMessage
  , errorFile
  , errorSource
  , errorLine
  , errorColumn
  ) where

import qualified Bindings.Libsass    as Lib
import           Control.Applicative ((<$>))
import           Control.Monad       ((>=>))
import           Foreign
import           Foreign.C
import           Text.Sass.Internal
import           Text.Sass.Options

-- | Represents compilation error.
data SassError = SassError {
    errorStatus  :: Int, -- ^ Compilation satus code.
    errorContext :: ForeignPtr Lib.SassContext
}

instance Show SassError where
    show (SassError s _) =
        "SassError: cannot compile provided source, error status: " ++ show s

instance Eq SassError where
    (SassError s1 _) == (SassError s2 _) = s1 == s2

-- | Result of compilation.
class SassResult a where
    toSassResult :: ForeignPtr Lib.SassContext -> IO a

instance SassResult String where
    toSassResult ptr = withForeignPtr ptr $ \ctx -> do
        result <- Lib.sass_context_get_output_string ctx
        !result' <- peekCString result
        return result'

-- | Loads specified property from context and converts it to desired type.
loadFromError :: (Ptr Lib.SassContext -> IO a) -- ^ Accessor function.
              -> (a -> IO b) -- ^ Conversion method.
              -> SassError -- ^ Pointer to context.
              -> IO b -- ^ Result.
loadFromError get conv err = withForeignPtr ptr $ get >=> conv
    where ptr = errorContext err

-- | Equivalent to @'loadFromError' 'get' 'peekCString' 'err'@.
loadStringFromError
    :: (Ptr Lib.SassContext -> IO CString) -- ^ Accessor function.
    -> SassError -- ^ Pointer to context.
    -> IO String -- ^ Result.
loadStringFromError get = loadFromError get peekCString

-- | Equivalent to @'loadFromError' 'get' 'fromInteger' 'err'@.
loadIntFromError :: (Integral a)
                 => (Ptr Lib.SassContext -> IO a) -- ^ Accessor function.
                 -> SassError -- ^ Pointer to context.
                 -> IO Int -- ^ Result.
loadIntFromError get = loadFromError get (return.fromIntegral)

-- | Loads information about error as JSON.
errorJson :: SassError -> IO String
errorJson = loadStringFromError Lib.sass_context_get_error_json

-- | Loads error text.
errorText :: SassError -> IO String
errorText = loadStringFromError Lib.sass_context_get_error_text

-- | Loads user-friendly error message.
errorMessage :: SassError -> IO String
errorMessage = loadStringFromError Lib.sass_context_get_error_message

-- | Loads file where problem occured.
errorFile :: SassError -> IO String
errorFile = loadStringFromError Lib.sass_context_get_error_file

-- | Loads error source.
errorSource :: SassError -> IO String
errorSource = loadStringFromError Lib.sass_context_get_error_src

-- | Loads line in the file where problem occured.
errorLine :: SassError -> IO Int
errorLine = loadIntFromError Lib.sass_context_get_error_line

-- | Loads line in the file where problem occured.
errorColumn :: SassError -> IO Int
errorColumn = loadIntFromError Lib.sass_context_get_error_column

-- | Common code for 'compileFile' and 'compileString'.
compileInternal :: (SassResult b)
                => CString -- ^ String that will be passed to 'make context'.
                -> SassOptions
                -> (CString -> IO (Ptr a)) -- ^ Make context.
                -> (Ptr a -> IO CInt) -- ^ Compile context.
                -> FinalizerPtr a -- ^ Context finalizer.
                -> IO (Either SassError b)
compileInternal str opts make compile finalizer = do
    -- Makes an assumption, that Sass_*_Context inherits from Sass_Context
    -- and Sass_Options.
    context <- make str
    let opts' = castPtr context
    copyOptionsToNative opts opts'
    status <- withFunctions opts opts' $ compile context
    fptr <- castForeignPtr <$> newForeignPtr finalizer context
    if status /= 0
        then return $ Left $
            SassError (fromIntegral status) fptr
        else do
            result <- toSassResult fptr
            return $ Right result


-- | Compiles file using specified options.
compileFile :: FilePath -- ^ Path to the file.
            -> SassOptions -- ^ Compilation options.
            -> IO (Either SassError String) -- ^ Error or output string.
compileFile path opts = withCString path $ \cpath ->
    compileInternal cpath opts
        Lib.sass_make_file_context
        Lib.sass_compile_file_context
        Lib.p_sass_delete_file_context

-- | Compiles raw Sass content using specified options.
compileString :: String -- ^ String to compile.
              -> SassOptions -- ^ Compilation options.
              -> IO (Either SassError String) -- ^ Error or output string.
compileString str opts = do
    cdata <- newCString str
    compileInternal cdata opts
        Lib.sass_make_data_context
        Lib.sass_compile_data_context
        Lib.p_sass_delete_data_context
