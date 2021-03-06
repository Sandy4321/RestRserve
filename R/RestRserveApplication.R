#' @name RestRserveApplication
#' @title Creates RestRserveApplication.
#' @description Creates RestRserveApplication object.
#' RestRserveApplication facilitates in turning user-supplied R code into high-performance REST API by
#' allowing to easily register R functions for handling http-requests.
#' @section Usage:
#' \itemize{
#' \item \code{app = RestRserveApplication$new()}
#' \item \code{app$add_route(path = "/echo", method = "GET", FUN =  function(request) {
#'   RestRserve::RestRserveResponse(body = request$query[[1]], content_type = "text/plain")
#'   })}
#' \item \code{app$routes()}
#' }
#' For usage details see \bold{Methods, Arguments and Examples} sections.
#' @section Methods:
#' \describe{
#'   \item{\code{$new()}}{Constructor for RestRserveApplication. For the moment doesn't take any parameters.}
#'   \item{\code{$add_route(path, method, FUN, path_as_prefix = FALSE, ...)}}{ Adds endpoint
#'   and register user-supplied R function as a handler.
#'   User function \code{FUN} \bold{must} return object of the class \bold{"RestRserveResponse"}
#'   which can be easily constructed with \link{RestRserveResponse}. \code{path_as_prefix} at the moment used
#'   mainly to help with serving static files. Probably in future it will be replaced with
#'   other argument to perform URI template matching.}
#'   \item{\code{$add_get(path, FUN, ...)}}{shorthand to \code{add_route} with \code{GET} method }
#'   \item{\code{$add_post(path, FUN, ...)}}{shorthand to \code{add_route} with \code{POST} method }
#'   \item{\code{$add_static(path, file_path, content_type = NULL, ...)}}{ adds GET method to serve
#'   file or directory at \code{file_path}. If \code{content_type = NULL}
#'   then MIME code \code{content_type}  will be inferred automatically (from file extension).
#'   If it will be impossible to guess about file type then \code{content_type} will be set to
#'   \code{"application/octet-stream"}}
#'   \item{\code{$run(http_port = 8001L, ...)}}{starts RestRserve application from current R session.
#'      \code{http_port} - http port for application.
#'      \code{...} - key-value pairs of the Rserve configuration. If contains \code{"http.port"} then
#'      \code{http_port} will be silently replaced with its value.
#'      \code{background} - whether to try to launch in background process on UNIX systems. Ignored in windows.}
#'   \item{\code{$call_handler(request)}}{Used internally, \bold{usually users} don't need to call it.
#'   Calls handler function for a given request.}
#'   \item{\code{$routes()}}{Lists all registered routes}
#'   \item{\code{$print_endpoints_summary()}}{Prints all the registered routes with allowed methods}
#'   \item{\code{$add_openapi(path = "/openapi.yaml", openapi = openapi_create())}}{Adds endpoint
#'   to serve \href{https://www.openapis.org/}{OpenAPI} description of available methods.}
#'   \item{\code{$add_swagger_ui(path = "/swagger", path_openapi = "/openapi.yaml",
#'                               path_swagger_assets = "/__swagger__/",
#'                               file_path = tempfile(fileext = ".html"))}}{Adds endpoint to show swagger-ui.}
#' }
#' @section Arguments:
#' \describe{
#'  \item{app}{A \code{RestRserveApplication} object}
#'  \item{path}{\code{character} of length 1. Should be valid path for example \code{'/a/b/c'}}
#'  \item{method}{\code{character} of length 1. At the moment one of
#'    \code{("GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH")}}
#'  \item{FUN}{\code{function} which takes \strong{single argument - \code{request}}.
#'    \code{request} essentially is a parsed http-request represented as R's \code{list} with following fields:
#'    \itemize{
#'      \item path
#'      \item method
#'      \item query
#'      \item body
#'      \item content_type
#'      \item headers
#'    }
#'  }
#' }
#' @format \code{\link{R6Class}} object.
#' @export
RestRserveApplication = R6::R6Class(
  classname = "RestRserveApplication",
  public = list(
    debug = NULL,
    debug_message = compiler::cmpfun(
      function(...) {
        if(self$debug)
          message(...)
        invisible(TRUE)
      }
    ) ,
    #------------------------------------------------------------------------
    initialize = function(middleware = list(), debug = FALSE) {
      stopifnot(is.list(middleware))
      self$debug = debug
      private$handlers = new.env(parent = emptyenv())
      private$handlers_openapi_definitions = new.env(parent = emptyenv())
      private$middleware = new.env(parent = emptyenv())
      do.call(self$append_middleware, middleware)
    },
    #------------------------------------------------------------------------
    add_route = function(path, method, FUN, path_as_prefix = FALSE, ...) {

      stopifnot(is.character(path) && length(path) == 1L)
      stopifnot(startsWith(path, "/"))

      method = private$check_method_supported(method)

      stopifnot(is.function(FUN))

      stopifnot(is.logical(path_as_prefix) && length(path_as_prefix) == 1L)

      # remove trailing slashes
      path = gsub(pattern = "/+$", replacement = "", x = path)
      # if path was a root -> replace it back
      if(path == "") path = "/"

      if( length(formals(FUN)) == 0L ) stop("function should take 2 arguments - 1. request 2. response")

      if( length(formals(FUN)) == 1L ) {
        warning("Function provided takes only 1 argument which willbe considered as request.
                Function should take two arguments - 1. request 2. response. This warning will be turned into ERROR next release!")
        FUN_WRAP = function(request, response) FUN(request)
      } else {
        FUN_WRAP = FUN
      }

      if(is.null(private$handlers[[path]]))
        private$handlers[[path]] = new.env(parent = emptyenv())

      if(!is.null(private$handlers[[path]][[method]]))
        warning(sprintf("overwriting existing '%s' method for path '%s'", method, path))

      CMPFUN = compiler::cmpfun(FUN_WRAP)
      attr(CMPFUN, "handle_path_as_prefix") = path_as_prefix
      private$handlers[[path]][[method]] = CMPFUN

      # try to parse functions and find openapi definitions
      openapi_definition_lines = extract_docstrings_yaml(FUN)
      # openapi_definition_lines = character(0) means
      # - there are no openapi definitions
      if(length(openapi_definition_lines) > 0) {

        if(is.null(private$handlers_openapi_definitions[[path]]))
          private$handlers_openapi_definitions[[path]] = new.env(parent = emptyenv())

        private$handlers_openapi_definitions[[path]][[method]] = openapi_definition_lines
      }

      invisible(TRUE)
    },
    # shortcuts
    add_get = function(path, FUN, ...) {
      self$add_route(path, "GET", FUN, ...)
    },

    add_post = function(path, FUN, ...) {
      self$add_route(path, "POST", FUN, ...)
    },
    # static files servers
    add_static = function(path, file_path, content_type = NULL, ...) {
      stopifnot(is_string_or_null(file_path))
      stopifnot(is_string_or_null(content_type))

      is_dir = file.info(file_path)[["isdir"]]
      if(is.na(is_dir)) {
        stop(sprintf("'%s' file or directory doesnt't exists", file_path))
      }
      # response = RestRserveResponse$new()
      # now we know file exists
      file_path = normalizePath(file_path)

      mime_avalable = FALSE
      if(is.null(content_type)) {
        mime_avalable = suppressWarnings(require(mime, quietly = TRUE))
        if(!mime_avalable) {
          warning(sprintf("'mime' package is not installed - content_type will is set to '%s'", "application/octet-stream"))
          mime_avalable = FALSE
        }
      }
      # file_path is a DIRECTORY
      if(is_dir) {
        self$debug_message("adding DIR ", file_path)
        handler = function(request, response) {
          fl = file.path(file_path, substr(request$path,  nchar(path) + 1L, nchar(request$path) ))

          if(!file.exists(fl)) {
            set_http_404_not_found(response)
          } else {
            content_type = "application/octet-stream"
            if(mime_avalable) content_type = mime::guess_type(fl)

            fl_is_dir = file.info(fl)[["isdir"]][[1]]
            if(isTRUE(fl_is_dir)) {
              set_http_404_not_found(response)
            }
            else {
              response$body = c(file = fl)
              response$content_type = content_type
              response$status_code = 200L
            }
          }
          forward()
        }
        self$add_get(path, handler, path_as_prefix = TRUE, ...)
      } else {
        self$debug_message("adding FILE ", file_path)
        # file_path is a FILE
        handler = function(request, response) {

          if(!file.exists(file_path))
            set_http_404_not_found(response)

          if(is.null(content_type)) {
            if(mime_avalable) {
              content_type = mime::guess_type(file_path)
            } else {
              content_type = "application/octet-stream"
            }
          }
          response$body = c(file = file_path)
          response$content_type = content_type
          response$status_code = 200L
          forward()
        }
        self$add_get(path, handler, ...)
      }
    },
    #------------------------------------------------------------------------
    call_handler = function(request, response) {
      TRACEBACK_MAX_NCHAR = 1000L
      PATH = request$path
      # placeholder
      self$debug_message("call_handler: creating dummy response")
      result = RestRserveResponse$new(body = "call_handler: should not happen - please report to https://github.com/dselivanov/RestRserve/issues",
               content_type = "text/plain",
               headers = character(0),
               status_code = 520L)

      if(identical(names(private$handlers), character(0))) {
        self$debug_message("call_handler: no registered endpoints - set 404 to response")
        set_http_404_not_found(response)
        return(forward())
      }


      METHOD = request$method
      FUN = private$handlers[[PATH]][[METHOD]]

      if(!is.null(FUN)) {
        self$debug_message("call_handler: happy path - found handler with exact match - executing")
        # call handler function. 4 results possible:
        # 1) object of RestRserveResponse - than we need to return it immediately - dowstream tasks will not touch it
        # 2) error - need to set corresponding response code and continue dowstream tasks
        # 3) RestRserveForward - considered as following: fuction modified response and we need to continue dowstream tasks
        # 4) anything else = set 500 error
        result = try_capture_stack(FUN(request, response))
        if(inherits(result, "RestRserveResponse")) {
          self$debug_message(sprintf("call_handler: got 'RestRserveResponse' from '%s' - finishing request-reponse cycle and returning result", PATH))
          return(result)
        } else {
          if(inherits(result, "simpleError")) {
            self$debug_message(sprintf("call_handler: got 'simpleError' from '%s' - creating 500 response with traceback", PATH))
            set_http_500_internal_server_error(response, get_traceback_message(result, TRACEBACK_MAX_NCHAR))
          } else {
            if(!inherits(result, "RestRserveForward")) {
              self$debug_message(sprintf("call_handler: result from %s handler doesn't return RestRserveResponse/RestRserveForward", PATH))
              set_http_500_internal_server_error(
                response,
                body = sprintf("handler for %s doesn't return RestRserveResponse/RestRserveForward object", PATH)
              )
            }
          }
          return(forward())
        }
      } else {
        self$debug_message(sprintf("call_handler: unhappy path - trying to match prefix path '%s'", PATH))
        # may be path is a prefix
        registered_paths = names(private$handlers)
        # add "/" to the end in order to not match not-complete pass.
        # for example registered_paths = c("/a/abc") and path = "/a/ab"
        handlers_match_start = startsWith(x = PATH, prefix = paste(registered_paths, "/", sep = ""))
        if(!any(handlers_match_start)) {
          self$debug_message(sprintf("call_handler: no path match prefix '%s'", PATH))
          set_http_404_not_found(response)
          return(forward())
        } else {
          paths_match = registered_paths[handlers_match_start]
          self$debug_message(sprintf("call_handler: matched paths to '%s' : %s",
                                     PATH, paste(paths_match, collapse = "|")))
          # find method which match the path - take longest match
          j = which.max(nchar(paths_match))
          matched_path = paths_match[[j]]
          self$debug_message(sprintf("call_handler: picking path '%s'", matched_path))
          FUN = private$handlers[[ matched_path ]][[METHOD]]
          # now FUN is NULL or some function
          # if it is a function then we need to check whther it was registered to handle patterned paths
          if(!isTRUE(attr(FUN, "handle_path_as_prefix"))) {
            self$debug_message(sprintf("call_handler: handler doesn't accept prefix paths"))
            set_http_404_not_found(response)
            return(forward())
          } else {
            # FIXME repeat of the happy path above
            # call handler function. 4 results possible:
            # 1) object of RestRserveResponse - than we need to return it immediately - dowstream tasks will not touch it
            # 2) error - need to set corresponding response code and continue dowstream tasks
            # 3) RestRserveForward - considered as following: fuction modified response and we need to continue dowstream tasks
            # 4) anything else = set 500 error
            result = try_capture_stack(FUN(request, response))
            if(inherits(result, "RestRserveResponse")) {
              self$debug_message(sprintf("call_handler: got 'RestRserveResponse' from '%s' - finishing request-reponse cycle and returning result", PATH))
              return(result)
            } else {
              if(inherits(result, "simpleError")) {
                self$debug_message(sprintf("call_handler: got 'simpleError' from '%s' - creating 500 response with traceback", PATH))
                set_http_500_internal_server_error(response, get_traceback_message(result, TRACEBACK_MAX_NCHAR))
              } else {
                if(!inherits(result, "RestRserveForward")) {
                  self$debug_message(sprintf("call_handler: result from %s handler doesn't return RestRserveResponse/RestRserveForward", PATH))
                  set_http_500_internal_server_error(
                    response,
                    body = sprintf("handler for %s doesn't return RestRserveResponse/RestRserveForward object", PATH)
                  )
                }
              }
              return(forward())
            }
          }
        }
      }
      result = RestRserveResponse$new(body = "call_handler: should not happen 2 - please report to https://github.com/dselivanov/RestRserve/issues",
                                      content_type = "text/plain",
                                      headers = character(0),
                                      status_code = 520L)
      return(result)
    },
    #------------------------------------------------------------------------
    routes = function() {
      endpoints = names(private$handlers)
      endpoints_methods = vector("character", length(endpoints))
      for(i in seq_along(endpoints)) {
        e = endpoints[[i]]
        endpoints_methods[[i]] = paste(names(private$handlers[[e]]), collapse = "; ")
      }
      names(endpoints_methods) = endpoints
      endpoints_methods
    },
    run = function(http_port = 8001L, ..., background = FALSE) {
      stopifnot(is.character(http_port) || is.numeric(http_port))
      stopifnot(length(http_port) == 1L)
      http_port = as.integer(http_port)
      ARGS = list(...)

      if( is.null(ARGS[["http.port"]]) ) {
        ARGS[["http.port"]] = http_port
      }

      keep_http_request = .GlobalEnv[[".http.request"]]
      keep_RestRserveApp = .GlobalEnv[["RestRserveApp"]]
      # restore global environment on exit
      on.exit({
        .GlobalEnv[[".http.request"]] = keep_http_request
        .GlobalEnv[["RestRserveApp"]] = keep_RestRserveApp
      })
      # temporary modify global environment
      .GlobalEnv[[".http.request"]] = RestRserve:::http_request
      .GlobalEnv[["RestRserveApp"]] = self
      self$print_endpoints_summary()
      if (.Platform$OS.type != "windows" && background) {

        pid = parallel::mcparallel(
            do.call(Rserve::run.Rserve, ARGS ),
          detached = TRUE)
        pid = pid[["pid"]]

        if(interactive()) {
          message(sprintf("started RestRserve in a BACKGROUND process pid = %d", pid))
          message(sprintf("You can kill process GROUP with `RestRserve:::kill_process_group(%d)`", pid))
          message("NOTE that current master process also will be killed")
        }
        pid
      } else {
        message(sprintf("started RestRserve in a FOREGROUND process pid = %d", Sys.getpid()))
        message(sprintf("You can kill process GROUP with `kill -- -$(ps -o pgid= %d | grep -o '[0-9]*')`", Sys.getpid()))
        message("NOTE that current master process also will be killed")
        do.call(Rserve::run.Rserve, ARGS )
      }
    },
    print_endpoints_summary = function() {
      registered_endpoints = self$routes()
      if(length(registered_endpoints) == 0)
        warning("'RestRserveApp' doesn't contain any endpoints")
      #------------------------------------------------------------
      # print registered methods
      #------------------------------------------------------------
      endpoints_summary = paste(names(registered_endpoints),  registered_endpoints, sep = ": ", collapse = "\n")
      message("------------------------------------------------")
      message(sprintf("starting service with endpoints:\n%s", endpoints_summary))
      message("-----------------------------------------------")
    },
    add_openapi = function(path = "/openapi.yaml",
                           openapi = openapi_create(),
                           file_path = "openapi.yaml",
                           ...) {
      stopifnot(is.character(file_path) && length(file_path) == 1L)
      file_path = path.expand(file_path)

      if(!require(yaml, quietly = TRUE))
        stop("please install 'yaml' package first")

      openapi = c(openapi, list(paths = private$get_openapi_paths()))

      file_dir = dirname(file_path)
      if(!dir.exists(file_dir))
        dir.create(file_dir, recursive = TRUE, ...)

      yaml::write_yaml(openapi, file = file_path, ...)
      # FIXME when http://www.iana.org/assignments/media-types/media-types.xhtml will be updated
      # for now use  "application/x-yaml":
      # https://www.quora.com/What-is-the-correct-MIME-type-for-YAML-documents
      self$add_static(path = path, file_path = file_path, content_type = "application/x-yaml", ...)
      invisible(file_path)
    },
    add_swagger_ui = function(path = "/swagger",
                              path_openapi = "/openapi.yaml",
                              path_swagger_assets = "/__swagger__/",
                              file_path = tempfile(fileext = ".html")) {
      stopifnot(is.character(file_path) && length(file_path) == 1L)
      file_path = path.expand(file_path)

      if(!require(swagger, quietly = TRUE))
        stop("please install 'swagger' package first")

      path_openapi = gsub("^/*", "", path_openapi)

      self$add_static(path_swagger_assets, system.file("dist", package = "swagger"))
      write_swagger_ui_index_html(file_path, path_swagger_assets = path_swagger_assets, path_openapi = path_openapi)
      self$add_static(path, file_path)
      invisible(file_path)
    },
    append_middleware = function(...) {
      middleware_list = list(...)
      # mw_names = names(middleware_list)
      # stopifnot(is.null(mw_names))
      # stopifnot(length(mw_names) != length(unique(mw_names)))
      # stopifnot(all(vapply(middleware_list, inherits, FALSE, "RestRserveMiddleware")))
      for(mw in middleware_list) {
        n_already_registered = length(private$middleware)
        id = as.character(n_already_registered + 1L)
        private$middleware[[id]] = mw
      }
      invisible(length(private$middleware))
    },
    call_middleware_request = function(request, response) {
      private$call_middleware(request, response, "process_request")
    },
    call_middleware_response = function(request, response) {
      private$call_middleware(request, response, "process_response")
    }
  ),
  private = list(
    handlers = NULL,
    handlers_openapi_definitions = NULL,
    middleware = NULL,
    process_request = function(request) {
      response = RestRserveResponse$new(body = "", content_type = "text/plain", headers = character(0), status_code = 200L)
      intermediate_response = self$call_middleware_request(request, response)
      # RestRserveResponse means we need to return result
      if(inherits(intermediate_response, "RestRserveResponse"))
        return(intermediate_response$as_rserve_response())

      intermediate_response = self$call_handler(request, response)
      if(inherits(intermediate_response, "RestRserveResponse"))
        return(intermediate_response$as_rserve_response())

      #call_middleware_response() can only retrun RestRserveForward or RestRserveResponse
      intermediate_response = self$call_middleware_response(request, response)
      if(inherits(intermediate_response, "RestRserveResponse"))
        return(intermediate_response$as_rserve_response())

      response$as_rserve_response()
    },
    # according to
    # https://github.com/s-u/Rserve/blob/d5c1dfd029256549f6ca9ed5b5a4b4195934537d/src/http.c#L29
    # only "GET", "POST", ""HEAD" are ""natively supported. Other methods are "custom"
    supported_methods = c("GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"),
    check_method_supported = function(method) {
      if(!is.character(method))
        stop(sprintf("method should be on of the [%s]", paste(private$supported_methods, collapse = ", ")))
      if(!(length(method) == 1L))
        stop(sprintf("method should be on of the [%s]", paste(private$supported_methods, collapse = ", ")))
      if(!(method %in% private$supported_methods))
        stop(sprintf("method should be on of the [%s]", paste(private$supported_methods, collapse = ", ")))
      method
    },
    get_openapi_paths = function() {
      paths = names(private$handlers_openapi_definitions)
      paths_descriptions = list()
      for(p in paths) {
        methods = names(private$handlers_openapi_definitions[[p]])
        methods_descriptions = list()
        for(m in methods) {

          yaml_string = enc2utf8(paste(private$handlers_openapi_definitions[[p]][[m]], collapse = "\n"))
          openapi_definitions_yaml = yaml::yaml.load(yaml_string,
                                                     handlers = list("float#fix" = function(x) as.numeric(x)))
          if(is.null(openapi_definitions_yaml))
            warning(sprintf("can't properly parse YAML for '%s - %s'", p, m))
          else
            methods_descriptions[[tolower(m)]] = openapi_definitions_yaml
        }
        paths_descriptions[[p]] = methods_descriptions
      }
      paths_descriptions
    },
    call_middleware = function(request, response, fun = c("process_request", "process_response")) {
      fun = match.arg(fun)

      if(fun == "process_request") {
        for(i in seq_along(private$middleware)) {
          id = as.character(i)
          self$debug_message("executing middleware '", id, "'-", fun)
          FUN = private$middleware[[id]][[fun]]
          mw_result = FUN(request, response)

          if(inherits(mw_result, "RestRserveResponse"))
            return(mw_result)

          if(!inherits(mw_result, "RestRserveForward")) {
            set_http_500_internal_server_error(
              response,
              body = sprintf("process_request middlware %s doesn't return RestRserveResponse/RestRserveForward object", id)
            )
            return(response)
          }
        }
      } else  {
        # execute 'process_response' middleware in reverse order
        # not sure yet what is the benefit, but it is done this way everywhere
        for(i in rev(seq_along(private$middleware))) {
          id = as.character(i)
          self$debug_message("executing middleware '", id, "'-", fun)
          FUN = private$middleware[[id]][[fun]]
          mw_result = FUN(request, response)
          if(inherits(mw_result, "RestRserveResponse"))
            return(mw_result)
          if(!inherits(mw_result, "RestRserveForward")) {
            set_http_500_internal_server_error(
              response,
              body = sprintf("process_response middlware %s doesn't return RestRserveResponse/RestRserveForward object", id)
            )
            return(response)
          }
        }
      }
      forward()
    }
  )
)
