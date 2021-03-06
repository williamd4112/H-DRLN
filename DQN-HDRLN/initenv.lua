--[[
Copyright (c) 2014 Google Inc.

See LICENSE file for full terms of limited license.
]]
dqn = {}

require 'torch'
require 'nn'
require 'nngraph'
require 'nnutils'
require 'image'
require 'Scale'
require 'NeuralQLearner'
require 'TransitionTable'
require 'Rectifier'


function torchSetup(_opt)
    _opt = _opt or {}
    local opt = table.copy(_opt)
    assert(opt)

    -- preprocess options:
    --- convert options strings to tables
    if opt.pool_frms then
        opt.pool_frms = str_to_table(opt.pool_frms)
    end
    if opt.env_params then
        opt.env_params = str_to_table(opt.env_params)
    end
    if opt.agent_params then
        opt.agent_params = str_to_table(opt.agent_params)
        opt.agent_params.gpu       = opt.gpu
        opt.agent_params.best      = opt.best
        opt.agent_params.verbose   = opt.verbose
        if opt.network ~= '' then
            opt.agent_params.network = opt.network
        end
    end

    --- general setup
    opt.tensorType =  opt.tensorType or 'torch.FloatTensor'
    torch.setdefaulttensortype(opt.tensorType)
    if not opt.threads then
        opt.threads = 4
    end
    torch.setnumthreads(opt.threads)
    if not opt.verbose then
        opt.verbose = 10
    end
    if opt.verbose >= 1 then
        print('Torch Threads:', torch.getnumthreads())
    end

    --- set gpu device
    if opt.gpu and opt.gpu >= 0 then
        require 'cutorch'
        require 'cunn'
        if opt.gpu == 0 then
            local gpu_id = tonumber(os.getenv('GPU_ID'))
            if gpu_id then opt.gpu = gpu_id+1 end
        end
        if opt.gpu > 0 then cutorch.setDevice(opt.gpu) end
        opt.gpu = cutorch.getDevice()
        print('Using GPU device id:', opt.gpu-1)
    else
        opt.gpu = -1
        if opt.verbose >= 1 then
            print('Using CPU code only. GPU device id:', opt.gpu)
        end
    end

    --- set up random number generators
    -- removing lua RNG; seeding torch RNG with opt.seed and setting cutorch
    -- RNG seed to the first uniform random int32 from the previous RNG;
    -- this is preferred because using the same seed for both generators
    -- may introduce correlations; we assume that both torch RNGs ensure
    -- adequate dispersion for different seeds.
    math.random = nil
    opt.seed = opt.seed or 1
    torch.manualSeed(opt.seed)
    if opt.verbose >= 1 then
        print('Torch Seed:', torch.initialSeed())
    end
    local firstRandInt = torch.random()
    if opt.gpu >= 0 then
        cutorch.manualSeed(firstRandInt)
        if opt.verbose >= 1 then
            print('CUTorch Seed:', cutorch.initialSeed())
        end
    end

    return opt
end


function setup(_opt)
    assert(_opt)

    --preprocess options:
    --- convert options strings to tables
    _opt.pool_frms = str_to_table(_opt.pool_frms)
    _opt.env_params = str_to_table(_opt.env_params)
    _opt.agent_params = str_to_table(_opt.agent_params)
    _opt.skill_agent_params = str_to_table(_opt.skill_agent_params)
    if _opt.agent_params.transition_params then
        _opt.skill_agent_params.transition_params =
            str_to_table(_opt.agent_params.transition_params)

        _opt.agent_params.transition_params =
            str_to_table(_opt.agent_params.transition_params)
    end

    --- first things first
    local opt = torchSetup(_opt)

    local distilled_hdrln = _opt.distilled_hdrln
    if distilled_hdrln == "true" then
      distilled_hdrln = true
    else
      distilled_hdrln = false
    end
    local supervised_skills = _opt.supervised_skills
    if supervised_skills == "true" then
      supervised_skills = true
    else
      supervised_skills = false
    end

    local num_skills = tonumber(_opt.num_skills)
    if args.supervised_file then
      local myFile = hdf5.open(args.supervised_file, 'r')
      num_skills = myFile:read('numberSkills'):all()
      myFile:close()
    end
    local gameEnv = nil

    local MCgameActions_primitive = {1,3,4,0,5} -- this is our game actions table
    local MCgameActions = MCgameActions_primitive:copy()
    local options = {} -- these actions are correlated to an OPTION, i.e an action the HDRLN selects that is mapped to a skill
    local optionsActions = {} -- for each skill we map availiable actions. Currently each skill maps all aviliable actions (doesn't have to be this way)

    local max_action_val = MCgameActions_primitive[1]
    for i = 2, #MCgameActions_primitive
    do
      max_action_val = max(max_action_val, MCgameActions_primitive[i])
    end

    for i = 1, num_skills
    do
      MCgameActions[#MCgameActions + 1] = i + max_action_val
      options[#options + 1] = i + max_action_val -- we want all actions mapped to skills to be larger than the maximal primitive action value
      optionsActions[#optionsActions + 1] = MCgameActions_primitive -- map all primitive actions for each skill
    end


    -- agent options
    _opt.agent_params.actions   = MCgameActions
    _opt.agent_params.options	= options
    _opt.agent_params.optionsActions = optionsActions
    _opt.agent_params.gpu       = _opt.gpu
    _opt.agent_params.best      = _opt.best
    _opt.agent_params.distilled_network = distilled_hdrln
    _opt.agent_params.distill   = false
    if _opt.agent_params.network then
	     print(_opt.agent_params.network)
	     _opt.agent_params.network = "convnet_atari_main"
    end
    --_opt.agent_params.network = "convnet_atari3"
    if _opt.network ~= '' then
        _opt.agent_params.network = _opt.network
    end

    _opt.agent_params.verbose = _opt.verbose
    if not _opt.agent_params.state_dim then
        _opt.agent_params.state_dim = gameEnv:nObsFeature()
    end
    if distilled_hdrln then -- distilled means single main network with multiple skills integrated into it
      _opt.skill_agent_params.actions   = MCgameActions_primitive
      _opt.skill_agent_params.gpu       = _opt.gpu
      _opt.skill_agent_params.best      = _opt.best
      _opt.skill_agent_params.distilled_network = true
      _opt.skill_agent_params.distill   = false
      _opt.agent_params.supervised_skills = supervised_skills
      _opt.agent_params.supervised_file = args.supervised_file
      if _opt.distilled_network ~= '' then
          _opt.skill_agent_params.network = _opt.distilled_network
      end
      _opt.skill_agent_params.verbose = _opt.verbose
      if not _opt.skill_agent_params.state_dim then
          _opt.skill_agent_params.state_dim = gameEnv:nObsFeature()
      end
      print("SKILL NETWORK")
      local distilled_agent = dqn[_opt.agent](_opt.skill_agent_params)
      print("END SKILL NETWORK")

      _opt.agent_params.skill_agent = distilled_agent
    else
      for i = 1, num_skills
      do
        _opt.skill_agent_params.actions   = MCgameActions_primitive
        _opt.skill_agent_params.gpu       = _opt.gpu
        _opt.skill_agent_params.best      = _opt.best
        _opt.skill_agent_params.distilled_network = false
        _opt.skill_agent_params.distill   = false
        if getlocal('_opt.skill_' .. i) ~= '' then
            _opt.skill_agent_params.network = getlocal('_opt.skill_' .. i)
        end
        _opt.skill_agent_params.verbose = _opt.verbose
        if not _opt.skill_agent_params.state_dim then
            _opt.skill_agent_params.state_dim = gameEnv:nObsFeature()
        end
        print("SKILL NETWORK " .. i)
    	  local skill_agent = dqn[_opt.agent](_opt.skill_agent_params)
        _opt.agent_params.skill_agent[#(_opt.agent_params.skill_agent) + 1] = skill_agent
        print("END SKILL NETWORK " .. i)
      end
    end

    _opt.agent_params.primitive_actions = MCgameActions_primitive
    print("MAIN AGENT")
    local agent = dqn[_opt.agent](_opt.agent_params)
    print("MAIN AGENT")
    if opt.verbose >= 1 then
        print('Set up Torch using these options:')
        for k, v in pairs(opt) do
            print(k, v)
        end
    end

    return gameEnv, MCgameActions_primitive, agent, opt
end



--- other functions

function str_to_table(str)
    if type(str) == 'table' then
        return str
    end
    if not str or type(str) ~= 'string' then
        if type(str) == 'table' then
            return str
        end
        return {}
    end
    local ttr
    if str ~= '' then
        local ttx=tt
        loadstring('tt = {' .. str .. '}')()
        ttr = tt
        tt = ttx
    else
        ttr = {}
    end
    return ttr
end

function table.copy(t)
    if t == nil then return nil end
    local nt = {}
    for k, v in pairs(t) do
        if type(v) == 'table' then
            nt[k] = table.copy(v)
        else
            nt[k] = v
        end
    end
    setmetatable(nt, table.copy(getmetatable(t)))
    return nt
end
