# gptel-openrouter

`gptel-openrouter` populates [gptel](https://github.com/karthink/gptel)
backends from OpenRouter's [complete text-output model catalog](https://openrouter.ai/api/v1/models?output_modalities=text).

It caches the catalog locally and refreshes it asynchronously, so starting
Emacs and opening the model selector never wait for the network. It maps API
metadata to gptel model properties, including:

- Input and output price per million tokens
- Context window and knowledge cutoff
- Reasoning, tool-use, JSON, and prompt-cache capabilities
- Image, PDF, audio, and video capability metadata
- Input and output modalities and accepted MIME types

This metadata automatically tells gptel which models can accept media, use tools, 
or return structured JSON, and improves the completion UI via Vertico/Marginalia.

## Installation

Clone this repository and add it to your load path:

```elisp
(add-to-list 'load-path "/path/to/gptel-openrouter")
(require 'gptel-openrouter)
```

With Straight:

```elisp
(use-package gptel-openrouter
  :straight (:type git :host github :repo "bharadswami/gptel-openrouter")
  :after gptel)
```

## Configuration

```elisp
(setq gptel-backend
      (gptel-openrouter-make-backend "OpenRouter"
        :key (getenv "OPENROUTER_API_KEY")
        :stream t))

(gptel-openrouter-auto-refresh-mode 1)
```

The first run uses `openrouter/auto` until the asynchronous download finishes.
Later runs load the cached catalog immediately. Refresh manually at any time
with `M-x gptel-openrouter-refresh-models`.

Multiple OpenRouter backends share the catalog and update together:

```elisp
(gptel-openrouter-make-backend "OpenRouter: xhigh effort"
  :key (getenv "OPENROUTER_API_KEY")
  :stream t
  :request-params '(:reasoning (:effort "xhigh")))
```

## Customization

Run `M-x customize-group RET gptel-openrouter` to change the cache location,
refresh interval, fallback models, catalog URL, or MIME types.

|Variable                           |Default                                                     |Description                                                                              |
|-----------------------------------|------------------------------------------------------------|-----------------------------------------------------------------------------------------|
|`gptel-openrouter-cache-file`      |`~/.emacs.d/gptel-openrouter/models.json`                   |Location of the cached API response.                                                     |
|`gptel-openrouter-refresh-interval`|`86400` (24 hours)                                          |Number of seconds between catalog refreshes.                                             |
|`gptel-openrouter-fallback-models` |`(openrouter/auto)`                                         |Models available before the first catalog download succeeds.                             |
|`gptel-openrouter-models-url`      |`https://openrouter.ai/api/v1/models?output_modalities=text`|OpenRouter catalog endpoint. Default limits the catalog to models capable of text output.|

For example, to store the cache under Emacs' cache directory and refresh it
every six hours:

```elisp
(setq gptel-openrouter-cache-file
      (expand-file-name "cache/openrouter-models.json" user-emacs-directory)
      gptel-openrouter-refresh-interval (* 6 60 60))
```

The package does not change how gptel makes requests or how it encodes or sends media. 

Model metadata processing uses gptel's internal `gptel--process-models`
function when installing a refreshed catalog into existing backends. This
function converts model specifications into gptel's model symbols and attaches
properties such as capabilities, prices, and context windows. gptel does not
currently expose an equivalent public API, so changes to that internal function
may require corresponding changes here.
