findMaxEigenValue = function(decoder) 
    local niter = 100 
    local Wd = decoder:get(2).weight:float()
    local inplane = decoder:get(2).weight:size(1)
    local outplane = decoder:get(2).weight:size(2) 
    local k = decoder:get(2).kW
    local k2 = 2*k-1
    local input = norm_filters(torch.rand(outplane,outplane,k2,k2)) 
    local input_prev = input:clone() 
    local output = input:clone():zero()
    local Sw = torch.Tensor(outplane,outplane,2*k-1,2*k-1) 
    for i = 1,outplane do
        Sw[i] = torch.conv2(Wd:select(2,i),flip(Wd),'F') 
    end
    print('Computing L...') 
    for i = 1,niter do 
        progress(i,niter)
        for i = 1,outplane do
            output[i] = torch.conv2(input:select(2,i),Sw,'F'):narrow(2,(k2-1)/2,k2):narrow(3,(k2-1)/2,k2) 
        end
        input_prev:copy(input) 
        input:copy(norm_filters(output))
    end
    local L = output:norm() 
    print('Found L='..L) 
    return L 
end

iter_infer = function(decoder,data,niter,l1w,L,method)
    --infer sparse code of dataset [ds] in dictionary [decoder] 
    method = method or 'FISTA' 
    local L = L or 1.05*findMaxEigenValue(decoder) 
    local n = 256 
    local outplane = decoder:get(2).weight:size(2) 
    local codes = torch.Tensor(data:size(1),outplane,data:size(3),data:size(4))
    local k = decoder:get(2).kW
    local padding = (k-1)/2
    local ConvDec = decoder:get(2) 
    --Thresholding-operator 
    local threshold = nn.Threshold(0,0):cuda()  
    local X = torch.CudaTensor(n,data:size(2),data:size(3),data:size(4))
    local Zprev = torch.zeros(n,outplane,data:size(3),data:size(4)):cuda()
    local Z = Zprev:clone() 
    local Y = Zprev:clone() 
    local Ynext = Zprev:clone() 
    local infer_FISTA = function(X)  
    --FISTA inference iterates
        local t = 1
        Zprev:fill(0)
        Y:fill(0)
        for i = 1,niter do 
            --ISTA
            Xerr = decoder:forward(Y):add(-1,X)  
            dZ = decoder:backward(Y,Xerr)   
            Z:copy(Y:add(-1/L,dZ))  
            Z:add(-l1w/L) 
            Z:copy(threshold(Z))
            ----FISTA 
            local tnext = (1 + math.sqrt(1+4*math.pow(t,2)))/2 
            Ynext:copy(Z)
            Ynext:add((1-t)/tnext,Zprev:add(-1,Z))
            --copies for next iter 
            Y:copy(Ynext)
            Zprev:copy(Z)
            t = tnext
        end
        return Y 
    end
    local infer_ISTA = function(X)  
    --ISTA inference iterates
        Zprev:fill(0)
        for i = 1,niter do 
            --ISTA
            Xerr = decoder:forward(Zprev):add(-1,X)  
            dZ = decoder:backward(Zprev,Xerr)   
            Z:copy(Zprev:add(-1/L,dZ))  
            Z:add(-l1w/L) 
            Z:copy(threshold(Z))
            Zprev:copy(Z)
        end
        return Z 
    end
    --infer codes for entire dataset 
    for i = 0,data:size(1)-n,n do 
        progress(i,data:size(1))
        X:copy(data:narrow(1,i+1,n))
        local code 
        if method == 'FISTA' then 
            code = infer_FISTA(X) 
        elseif method == 'ISTA' then 
            code = infer_ISTA(X) 
        end
        codes:narrow(1,i+1,n):copy(code) 
    end
    --process the remaining data 
    local a = math.floor(data:size(1)/n)*n+1
    local b = math.fmod(data:size(1),n)
    if a < data:size(1) then 
        X = torch.CudaTensor(b,X:size(2),X:size(3),X:size(4))
        Zprev = torch.zeros(b,outplane,X:size(3),X:size(4)):cuda()
        Z = Zprev:clone() 
        Y = Zprev:clone() 
        Ynext = Zprev:clone() 
        X:copy(data:narrow(1,a,b))
       -- Y = infer(X)
        codes:narrow(1,a,b):copy(Y)  
    end 
    --clean up  
    X = nil 
    Zprev = nil 
    Z = nil 
    Ynext = nil 
    Y = nil 
    collectgarbage() 
    return codes
end

--(1) s.g.d. minimization of L = ||x-Df(x)|| + l1w*|f(x)| w.r.t. f() (and D if [fix_decoder]==false)  
minimize_lasso_sgd = function(encoder,decoder,fix_decoder,ds,l1w,learn_rate,epochs,recurrent,save_dir)
    recurrent = recurrent or false 
    local sizeAverage = false
    if save_dir ~= nil then  
        local record_file = io.open(save_dir..'output.txt', 'a') 
        record_file:write('Training Output:\n') 
        record_file:close()
    end
    local inplane = decoder:get(2).weight:size(1)
    local outplane = decoder:get(2).weight:size(2) 
    
    
    local rec_criterion = nn.ParallelCriterion() 
    local l1_criterion = nn.ParallelCriterion() 
    local X = ds:next() 
    local Z = encoder:forward(X)
    
    if type(Z) == 'table' then  
        --recurrent-style training (multi-output) 
        rec_criterion = nn.ParallelCriterion() 
        l1_criterion = nn.ParallelCriterion() 
        local decoder_parallel = nn.ConcatTable()                                                                                                                  
        for i = 1,#Z do 
            decoder_parallel:add(decoder)
            local c1 = nn.MSECriterion()
            c1.sizeAverage = sizeAverage 
            local c2 = nn.L1Criterion()
            c2.sizeAverage = sizeAverage 
            rec_criterion:add(c1) 
            l1_criterion:add(c2) 
        end
        decoder = decoder_parallel 
    else 
        --ordinary training (single-output) 
        rec_criterion = nn.MSECriterion() 
        l1_criterion = nn.L1Criterion() 
    end
end 

--use gpu 
rec_criterion:cuda() 
l1_criterion:cuda() 
encoder:cuda() 
decoder:cuda()

local loss_plot = torch.zeros(epochs)

for iter = 1,epochs do 
    local epoch_loss = 0 
    local epoch_sparsity = 0 
    local epoch_rec_error = 0 
    sys.tic() 
    for i = 1, ds:size() do 
       progress(i,ds:size()) 
       local X = ds:next()
       local Z = encoder:forward(X) 
       local Xr = decoder:forward(Z)
       local rec_error = rec_criterion:forward(Xr,X)   
       local rec_grad = rec_criterion:backward(Xr,X):mul(0.5) --MSE criterion multiplies by 2 
       local dZrec = decoder:backward(Z,rec_grad) 
       --training a decoder 
       if fix_decoder == false then 
        decoder:zeroGradParameters()
        decoder:updateParameters(learn_rate) 
       end 
       local l1_error = l1_criterion:forward(Z) 
       local dZl1 = l1_criterion:backward(Z):mul(l1w) 
       local dZ = dZrec+dZl1 
       encoder:zeroGradParameters()
       encoder:backward(X,dZ) 
       --track loss 
       local sample_sparsity = 1-(Z:float():gt(0):sum()/Z:nElement())
       local sample_loss = rec_error + l1_error  
       epoch_rec_error = epoch_rec_error + sample_rec_error
       epoch_sparsity = epoch_sparsity + sample_sparsity 
       epoch_loss = epoch_loss + sample_loss 
    end
    local epoch_rec_error = epoch_rec_error/ds:size() 
    local average_loss = epoch_loss/ds:size()  
    loss_plot[iter] = average_loss
    local average_sparsity = epoch_sparsity/ds:size() 
    local output = tostring(iter)..' Time: '..sys.toc()..' %Rec.Error '..epoch_rec_error..' Sparsity:'..average_sparsity..' Loss: '..average_loss 
    print(output) 
    if save_dir ~= nil then  
        local record_file = io.open(save_dir..'output.txt', 'a') 
        record_file:write(output..'\n') 
        record_file:close()
    end
end 
if save_dir ~= nil then 
    gnuplot.plot(loss_plot,'.')
    gnuplot.plotflush()
    gnuplot.figprint(save_dir..'train_loss.pdf')
    gnuplot.closeall() 
end 
return encoder,loss_plot 
end

construct_deep_net = function(decoder,nlayers,untied_weights,config)
--deep ReLU network with [optionally] shared weights (inialized identically to LISTA) 
    print('Initilizing deep ReLU from LISTA init') 
    local inplane = decoder:get(2).weight:size(1)
    local outplane = decoder:get(2).weight:size(2) 
    local k = decoder:get(2).kW
    local We = nn.SpatialConvolution(inplane,outplane,k,k) 
    We.weight:copy(flip(decoder:get(2).weight)) 
    We.bias:fill(0)
    local LISTA = construct_LISTA(We,1,config.l1w,config.L,config.untied_weights)
    local pad1 = LISTA.pad1
    local pad2 = LISTA.pad2
    local conv1 = LISTA.encoder 
    local conv = LISTA.S 
    local net = nn.Sequential() 
    net:add(pad1:clone())
    net:add(conv1) 
    net:add(nn.Threshold(0,0))
    for i=2,nlayers do 
        local conv_clone = conv:clone()         
        if untied_weights==false then  
            conv_clone:share(conv, 'weight') 
            conv_clone:share(conv, 'bias') 
        end 
        net:add(pad2:clone()) 
        net:add(conv_clone) 
        net:add(nn.Threshold(0,0))
    end
    return net 
end

construct_LISTA = function(encoder,nloops,alpha,L,untied_weights,recurrent)
--[We] = encoder (linear operator) 
--[S] = 'explaining-away' (square linear operator)
--[n] = number of LISTA loops 
--WARNING: Assumes CudaTensor  
    encoder = encoder:clone() 
    local alpha = alpha or 0.5 
    --initialize S 
    local S = nn.Sequential() 
    if torch.typename(encoder) == 'nn.Linear' then 
        local We = encoder.weight:float()
        local D = We:size(1) 
        local Sw = torch.mm(We,We:t()) 
        local _,L,_ = math.sqrt(torch.svd(We)[1]) 
        Sw = torch.eye(D,D) - torch.mm(We,We:t()):div(L)   
        S:add(nn.Linear(D,D))
        S:get(1).weight:copy(Sw) 
        S:get(1).bias:fill(-alpha/L)
        S:cuda()
        encoder:cuda()
    elseif string.find(torch.typename(encoder),'nn.SpatialConvolution') then 
        print('Initializing convolutional LISTA...') 
        -- flip because conv2 flips whereas nn.SpatialConvolution will not 
        local We = flip(encoder.weight) 
        --dimensions (assume square, odd-sized kernels and stride = 1) 
        local inplane = We:size(1) 
        local outplane = We:size(2)
        local k = We:size(3)
        local padding = (k-1)/2
        local pad = nn.SpatialPadding(padding,padding,padding,padding,3,4) 
        local pad2 = nn.SpatialPadding(2*padding,2*padding,2*padding,2*padding,3,4) 
        local Sw = torch.Tensor(outplane,outplane,2*k-1,2*k-1) 
        for i = 1,outplane do
            Sw[i] = torch.conv2(We:select(2,i),flip(We),'F') 
        end
        --find L using power method
        if L == nil then  
            local k2 = 2*k-1
            local input = norm_filters(torch.rand(outplane,outplane,k2,k2)) 
            local input_prev = input:clone() 
            local output = input:clone():zero()
            for i = 1,100 do 
                progress(i,100)
                for i = 1,outplane do
                    output[i] = torch.conv2(input:select(2,i),Sw,'F'):narrow(2,(k2-1)/2,k2):narrow(3,(k2-1)/2,k2) 
                end
                input_prev:copy(input) 
                input:copy(norm_filters(output))
            end
            L = output:norm() 
        end
        Sw:div(L) 
        local I = torch.zeros(outplane,outplane,2*k-1,2*k-1) 
        for i = 1,outplane do 
            I[i][i][math.ceil(k-0.5)][math.ceil(k-0.5)] = 1 
        end
        Sw = I - Sw
        S:add(pad2:clone()) 
        S:add(nn.SpatialConvolution(outplane,outplane,2*k-1,2*k-1))
        S:get(2).weight:copy(Sw) 
        S:get(2).bias:fill(0)
        S:cuda() 
        encoder.weight:div(L) 
        encoder.bias:fill(-alpha/L)
        local encoder_same = nn.Sequential() 
        encoder_same:add(pad:clone()) 
        encoder_same:add(encoder) 
        encoder = encoder_same:cuda() 
    else 
        error('Unsupported LISTA encoder') 
    end
    
    --nngraph module 
    local x = nn.Identity()() 
    local z = {}
    --first stage 
    local t1 = encoder(x) 
    local t1a,t1b = nn.ConcatTable():add(nn.Identity()):add(nn.Identity())(t1):split(2)
    if nloops == 0 then 
        z[1] = nn.Threshold(0,0)(t1a) 
        local net = nn.gModule({x},z)
        net.encoder = encoder:get(2)  
        net:cuda()
        return net 
    end 
    --internal stages
    local nloops = nloops or 1
    for i = 1, nloops do 
        local t2 = nn.Threshold(0,0)(t1a) 
        z[#z+1]=t2 
        local t3 = S(t2)
        local sum = nn.CAddTable()({t1b,t3})
        t1a = sum  
    end
    z[#z+1] = nn.Threshold(0,0)(t1a)
   
    local net 
    if recurrent == true then 
        net = nn.gModule({x},z) 
    else 
        net = nn.gModule({x},z[#z]) 
    end
    net.S = S:get(2) 
    return net
end 







