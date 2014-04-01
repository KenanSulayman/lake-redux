#!/usr/bin/env coffee

# Std library
fs = require 'fs'
path = require 'path'
{exec} = require 'child_process'
{inspect} = require 'util'

# Third party
mkdirp = require 'mkdirp'
async = require 'async'
debug = require('debug')('create-makefile')
eco = require 'eco'
{_} = require 'underscore'

# Local dep
{createLocalMakefileInc} = require './create_mk'
{
    findProjectRoot
    locateNodeModulesBin
    getFeatureList
} = require './file-locator'

Manifest = require './manifest-class'

mergeObject = (featureTargets, globalTargets) ->
    for key, value of featureTargets
        unless globalTargets[key]?
            globalTargets[key] = []
        unless _(_(value).flatten()).isEmpty()
            globalTargets[key].push value

    return


createMakefiles = (input, output, global, cb) ->

    async.waterfall [
        (cb) ->
            debug 'locateNodeModulesBin'
            locateNodeModulesBin cb

        (binPath, cb) ->
            debug 'findProjectRoot'
            findProjectRoot (err, projectRoot) ->
                if err? then return cb err
                cb null, binPath, projectRoot

        (binPath, projectRoot, cb) ->
            debug 'retrieve feature list'
            if input?
                cb null, binPath, projectRoot, [input]
            else
                getFeatureList (err, list) ->
                    if err? then return cb err
                    cb null, binPath, projectRoot, list

        (binPath, projectRoot, featureList, cb) ->
            lakeConfigPath = path.join projectRoot, '.lake', 'config'

            ###
            # don't check file existence with extension
            # it should be flexible coffee or js, ...?
            ###
            #unless (fs.existsSync lakeConfigPath)
            #    throw new Error "lake config not found at #{lakeConfigPath}"

            lakeConfig = require lakeConfigPath
            mkFiles = []
            globalTargets = {}

            # Default output points to current behavior: .lake/build
            # This can be changed once all parts expect the includes at build/lake
            output ?= path.join lakeConfig.lakePath, 'build'

            # queue worker function
            q = async.queue (manifest, cb) ->
                console.log "Creating .mk file for #{manifest.featurePath}"
                createLocalMakefileInc lakeConfig, manifest, output,
                (err, mkFile, globalFeatureTargets) ->
                    if err? then return cb err

                    mergeObject globalFeatureTargets, globalTargets

                    debug "finished with #{mkFile}"
                    cb null, mkFile
                    
            , 4

            errorMessages = []
            for featurePath in featureList
                manifest = null
                try
                    manifest = new Manifest projectRoot, featurePath

                catch err
                    err.message = "Error in Manifest #{featurePath}: " +
                    "#{err.message}"
                    debug err.message
                    return cb err

                q.push manifest, (err, mkFile) ->
                    if not err?
                        debug "created #{mkFile}"
                        mkFiles.push mkFile
                    else
                        message = 'failed to create Makefile.mk for ' +
                        "#{featurePath}: #{err}"
                        debug message
                        errorMessages.push message

        
            # will be called when queue proceeded last item
            # TODO: why this assignment have to be in this scope
            # and not a scope more outer
            q.drain = ->
                debug 'Makefile generation finished ' +
                'for feature all features in .lake'
                debug globalTargets
                if errorMessages.length
                    cb new Error "failed to create Makefile" + errorMessages
                else
                    cb null, lakeConfig, binPath, projectRoot, mkFiles,
                        globalTargets

        (lakeConfig, binPath, projectRoot, mkFiles, globalTargets, cb) ->
            global ?= path.join projectRoot, 'Makefile'
            # Don't write a top-level Makefile if we only want to create one include
            if input?
                stream = fs.createWriteStream global
                stream.on 'error', (err) ->
                    console.error 'error occurs during streaming global Makefile'
                    return cb err

                stream.once 'finish', ->
                    debug 'Makefile stream finished'
                    return cb null
                writeGlobalRulesToStream stream, globalTargets
            else
                # create temp Makefile.eco
                debug 'open write stream for Makefile'
                #stream = fs.createWriteStream path.join(projectRoot, 'Makefile')
                stream = fs.createWriteStream global
                stream.on 'error', (err) ->
                    console.error 'error occurs during streaming global Makefile'
                    return cb err

                stream.once 'finish', ->
                    debug 'Makefile stream finished'
                    return cb null

                writeMakefileToStream stream, lakeConfig, binPath, projectRoot,
                    mkFiles, globalTargets
                debug 'written it'

        ], cb

writeGlobalRulesToStream = (stream, globalTargets) ->
    # global targets, added by RuleBook API
    for targetName, dependencies of globalTargets
        stream.write "#{targetName}: #{dependencies.join ' '}\n"

writeMakefileToStream = (stream, lakeConfig, binPath, projectRoot, mkFiles,
        globalTargets) ->
    stream.write '# this file is generated by lake\n'
    stream.write "# generated at #{new Date()}\n"
    stream.write '\n'

    # assigments
    # built-in assignments
    stream.write "ROOT := #{projectRoot}\n"
    stream.write "NODE_BIN := #{binPath}\n"
    stream.write '\n'

    # custom assignments
    for assignment in lakeConfig.makeAssignments
        for left, right of assignment
            stream.write "#{left} := #{right}\n"

    stream.write '\n'

    # default (first) rule
    defaultRule = lakeConfig.makeDefaultTarget
    if defaultRule.target?
        stream.write defaultRule.target
        if defaultRule.dependencies?
            stream.write ": #{defaultRule.dependencies}"
        stream.write '\n'
        if defaultRule.actions?
            stream.write '\t' + _([defaultRule.actions]).flatten().join '\n\t'

    # includes (Makefile.mk)
    stream.write '\n'
    stream.write ("include #{file}" for file in mkFiles).join '\n'
    stream.write '\n\n'

    # global targets, added by RuleBook API
    writeGlobalRulesToStream stream, globalTargets

    stream.write '\n'

    # global targets, added by .lake/config.js/.coffee
    if lakeConfig.globalRules?
        stream.write lakeConfig.globalRules + '\n'

    debug 'write last line to stream, trigger close event'
    stream.end()


if require.main is module
    createMakefiles (err) ->
        if err?
            console.error "error: #{err}"
            process.exit 1
        else
            console.log 'created global Makefile'

else
    module.exports = {
        createMakefiles
        writeMakefileToStream
    }
