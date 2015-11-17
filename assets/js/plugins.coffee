# TODO: Handle dependencies automatically for the notion of "enabled" plugins.
#       pluginEnabled  - Return true if it's a dependency of something enabled
#       enablePlugin   - Enable required dependencies first
#       disablePlugin  - Unload any dependency which isn't explicitly enabled or required by another enabled plugin.

if module?
  global._ = require('lodash')
  global.tv4 = require('tv4')

  global.Logger = require('./logger.coffee')
  global.errors = require('./errors.coffee')
  global.DependencyGraph = require('dependencies-online')

(() ->
  # class for exposing plugin API
  class PluginApi
    constructor: (@view, @plugin_metadata, @pluginManager) ->
      @name = @plugin_metadata.name
      @data = @view.data
      @cursor = @view.cursor
      # TODO: Add subloggers and prefix all log messages with the plugin name
      @logger = Logger.logger

    getDataVersion: () ->
      @data.store.getPluginDataVersion @name

    setDataVersion: (version) ->
      @data.store.setPluginDataVersion @name, version

    setData: (key, value) ->
      @data.store.setPluginData @name, key, value

    getData: (key) ->
      @data.store.getPluginData @name, key

    getPlugin: (name) ->
      @pluginManager.getPlugin name

    panic: _.once () =>
      alert "Plugin '#{@name}' has encountered a major problem. Please report this problem to the plugin author."
      @pluginManager.disablePlugin @name

  # Core plugins are always enabled and can never be disabled (e.g. bold/italic)
  CORE_PLUGINS = {
  }

  # Other plugins are maintained in a list of "enabled plugins", which default to this value. Plugins are disabled by default.
  DEFAULT_ENABLED_PLUGINS = {
    "Hello World coffee": true
    "Hello World js": true
  }

  PLUGIN_SCHEMA = {
    title: "Plugin metadata schema"
    type: "object"
    required: [ 'name' ]
    properties: {
      name: {
        description: "Name of the plugin"
        pattern: "^[A-Za-z0-9_ ]{3,20}$"
        type: "string"
      }
      version: {
        description: "Version of the plugin"
        type: "number"
        default: 1
        minimum: 1
      }
      author: {
        description: "Author of the plugin"
        type: "string"
      }
      description: {
        description: "Description of the plugin"
        type: "string"
      }
      dependencies: {
        description: "Dependencies of the plugin - a list of other plugins"
        type: "array"
        items: { type: "string" }
        default: []
      }
      dataVersion: {
        description: "Version of data format for plugin"
        type: "integer"
        default: 1
        minimum: 1
      }
    }
  }

  # shim for filling in default values, with tv4
  tv4.fill_defaults = (data, schema) ->
    for prop, prop_info of schema.properties
      if prop not of data
        if 'default' of prop_info
          data[prop] = prop_info['default']

  class PluginsManager
    constructor: (options) ->
      @enabledPlugins = DEFAULT_ENABLED_PLUGINS # Will be overridden before plugin loading, during 'resolveView'
      @plugins = {}
      @pluginDependencies = new DependencyGraph

    validate: (plugin_metadata) ->
      if not tv4.validate(plugin_metadata, PLUGIN_SCHEMA, true, true)
        throw new errors.GenericError(
          "Error validating plugin #{JSON.stringify(plugin_metadata, null, 2)}: #{JSON.stringify(tv4.error)}"
        )
      tv4.fill_defaults plugin_metadata, PLUGIN_SCHEMA

    resolveView: (view) ->
      @view = view
      enabledPlugins = view.settings.getSetting "enabledPlugins"
      if enabledPlugins?
        @enabledPlugins = enabledPlugins
      @pluginDependencies.resolve '_view', view

    getPluginNames: () ->
      _.keys @plugins

    status: (name) -> # Returns one of: Unregistered Registered Loading (Disabled|Loaded)
      @plugins[name]?.status || "Unregistered"

    enablePlugin: (name) ->
      @enabledPlugins[name] = true
      @view.settings.setSetting "enabledPlugins", @enabledPlugins
      if (@status name) in ["Disabled"] # If it's ready to load
        @load @plugins[name]

    disablePlugin: (name) ->
      delete @enabledPlugins[name]
      @view.settings.setSetting "enabledPlugins", @enabledPlugins
      if (@status name) in ["Loaded"] and not @pluginEnabled name # calling disablePlugin CORE-PLUGIN still does not disable it
        @unload @plugins[name]

    getPlugin: (name) ->
      @plugins[name]?.value

    pluginEnabled: (name) ->
      (name of CORE_PLUGINS) or (name of @enabledPlugins)

    unload: (plugin) ->
      if plugin.unload
        plugin.unload plugin.value
      else
        # Default unload method, which is to tell the user to refresh
        @_displayUnloadAlert ?= _.once (plugin) ->
          alert "The plugin '#{plugin.name}' was disabled. Refresh to unload all disabled plugins."
        @_displayUnloadAlert plugin
      delete plugin.value
      plugin.status = "Disabled"

    load: (plugin) ->
      if @pluginEnabled plugin.name
        api = new PluginApi @view, plugin, @

        # validate data version
        dataVersion = do api.getDataVersion
        unless dataVersion?
          api.setDataVersion plugin.dataVersion
          dataVersion = plugin.dataVersion
        # TODO: Come up with some migration system for both vimflowy and plugins
        errors.assert_equals dataVersion, plugin.dataVersion,
          "Plugin data versions are not identical, please contact the plugin author for migration support"

        Logger.logger.info "Plugin #{plugin.name} loading"
        plugin.value = plugin.enable api
        @pluginDependencies.resolve plugin.name, plugin.value
        plugin.status = "Loaded"
        Logger.logger.info "Plugin #{plugin.name} loaded"
      else
        plugin.status = "Disabled"

    register: (plugin_metadata, enable, disable) ->
      @validate plugin_metadata
      errors.assert enable?, "Plugin #{plugin_metadata.name} needs to register with a callback"

      # Create the plugin object
      # Plugin stores all data about a plugin, including metadata
      # plugin.value contains the actual resolved value
      plugin = _.cloneDeep plugin_metadata
      plugin.originalMetadata = plugin_metadata
      @plugins[plugin.name] = plugin
      plugin.enable = enable
      plugin.disable = disable
      plugin.dependencies = _.clone (_.result plugin_metadata, 'dependencies', [])
      plugin.dependencies.push '_view'
      Logger.logger.info "Plugin #{plugin.name} registered"

      # Load the plugin after all its dependencies have loaded
      plugin.status = "Registered"
      (@pluginDependencies.add plugin.name, plugin.dependencies).then () =>
        plugin.status = "Loading"
        @load plugin

  Plugins = new PluginsManager

  # exports
  module?.exports = Plugins
  window?.Plugins = Plugins
)()