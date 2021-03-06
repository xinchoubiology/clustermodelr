#' Model clustered, correlated data
#'
#' clustermodelr provides a consistent, simple interface to model correlated
#' data using a number of different methds:
#' \describe{ 
#' \item{GEE:}{Generalized Estimating Equations with all correlation structures
#'            available from \code{geepack}. \code{\link{geer}}}
#' \item{mixed-effect model:}{Mixed effect model in \link[lme4]{lme4} syntax
#'                           \code{\link{mixed_modelr}}}
#' \item{combiner:}{Calculates the p-value for each entry in the cluster then
#'                combines the p-values adjusting for correlation with either
#'                \code{\link{stouffer_liptak.combine}} or
#'                \code{\link{zscore.combine}}}
#' \item{bumping:}{something like bump-hunting but takes a putative "bump" and
#'                repeatedly compares coefficients of estimated covariates to the observed
#'                to assign significance. \code{\link{bumpingr}}}
#' \item{SKAT:}{SKAT already accepts a matrix to test a null model. This just
#'             provides an interface that matches the rest of the functions in
#'             this package \code{\link{skatr}}}
#' }
#' 
#' @details
#' Each of these functions will accept a formula like:
#' 
#' \code{methylation ~ disease + age}
#'
#' (with a random intercept for mixed_modelr)
#' where \code{methylation} need not be methylation values, but is assumed to be
#' a matrix of correlated values.
#' 
#' For each of these functions, the \strong{return value} will be a vector of:
#' 
#' \code{c(covariate, p, coef.estimate)} 
#' 
#' where the covariate is taken as the first
#' element on the RHS of the formula so \emph{disease} in the formula above.
#'
#' @docType package
#' @name clustermodelr



suppressPackageStartupMessages(library("limma", quietly=TRUE))


#' Run lm on a single site
#' 
#' Unlike most of the function in this package, this function is used on a
#' single site.
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param methylation a single column matrix or a vector the same length
#'        as \code{nrow(covs)}
#' @param weights optional weights for lm
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
lmr = function(formula, covs, methylation=NULL, weights=NULL){
    if(!is.null(methylation)) covs$methylation = methylation
    if(is.null(weights)){
        s = summary(lm(formula, covs))$coefficients
    } else {
        covs$weights = weights
        s = summary(lm(formula, covs, weights=weights, na.action=na.omit))$coefficients
    }
    covariate = rownames(s)[2]
    row = s[2,]
    list(covariate=covariate, p=row[['Pr(>|t|)']], coef=row[['Estimate']])
}

betaregr = function(formula, covs, meth, wweights, combine=c('liptak', 'z-score')){
    suppressPackageStartupMessages(library('betareg', quietly=TRUE))
    combine = match.arg(combine)
    meth[meth == 1] = 0.99
    meth[meth == 0] = 0.01
    if(ncol(meth) == 1){ return(betaregr.one(formula, covs, meth[,1], wweights[,1])) }
    res = lapply(1:ncol(meth), function(icol){
        betaregr.one(formula, covs, meth[,icol], wweights[,icol])
    })
    ilogit = function(x) 1 / (1 + exp(-x)) 

    pvals = unlist(lapply(1:length(res), function(i){ res[[i]]$p }))
    sigma = abs(cor(meth, method="spearman", use="pairwise.complete.obs"))
    w = log2(1 + colMeans(wweights))
    combined.p = zscore.combine(pvals, sigma, weights=w)
    #intercept = weighted.mean(unlist(lapply(1:length(res), function(i){ res[[i]]$intercept })))
    coef = weighted.mean(unlist(lapply(1:length(res), function(i){ 
        res[[i]]$coef
    })), w)
    list(covariate=res[[1]]$covariate, p=combined.p, coef=coef)
}

betaregr.one = function(formula, covs, methylation, wweights){
    covs$methylation = methylation
    covs$counts = covs$weights=wweights
    s = summary(betareg(formula, covs, weights=covs$weights, link="logit"))$coefficients$mean
    covariate = rownames(s)[2]
    row = s[2,]
    list(covariate=covariate, p=row[['Pr(>|z|)']], coef=row[['Estimate']], intercept=s[["(Intercept)", "Estimate"]])
}


#' Run lm on each column in a cluster and combine p-values with the 
#' either stouffer-liptak or zscore method.
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a matrix of correlated data.
#' @param cor.method either "spearman" or "pearson"
#' @param combine.fn a function that takes a list of p-values and
#'        a correlation matrix and returns a combined p-value
#'        \code{\link{stouffer_liptak.combine}} or \code{\link{zscore.combine}}
#' @param weights optional weights matrix of same shape as meth
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
combiner = function(formula, covs, meth, cor.method="spearman",
                            combine.fn=stouffer_liptak.combine, weights=NULL){
    covs$methylation = 1 #
    mod = model.matrix(formula, covs)
    # if there is missing data, have to send to another function.
    if(any(is.na(meth)) | nrow(mod) != nrow(covs)){
        return(combiner.missing(formula, covs, meth, cor.method, combine.fn,
                                weights=weights))
    }
    library(limma)
    sigma = abs(cor(meth, method=cor.method))
    stopifnot(nrow(sigma) == ncol(meth))
    meth = t(meth)
    if(!is.null(weights)){ weights = t(weights) }

    covariate = colnames(mod)[1 + as.integer(colnames(mod)[1] == "(Intercept)")]

    fit = eBayes(lmFit(meth, mod, weights=weights))
    beta.orig = coefficients(fit)[,covariate]
    pvals = topTable(fit, coef=covariate, number=Inf, sort.by='none')[,"P.Value"]
    beta.ave = sum(beta.orig) / length(beta.orig)
    p = combine.fn(pvals, sigma)
    return(list(covariate=covariate, p=p, coef=beta.ave))
}

#' Run lm on each column in a cluster and combine p-values with the 
#' Stouffer-Liptak method or the z-score method. Missing data OK.
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a matrix of correlated data.
#' @param weights optional weights matrix of same shape as meth
#' @param cor.method either "spearman" or "pearson"
#' @param combine.fn a function that takes a list of p-values and
#'        a correlation matrix and returns a combined p-value
#'        \code{\link{stouffer_liptak.combine}} or \code{\link{zscore.combine}}
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
combiner.missing = function(formula, covs, meth, weights=NULL, cor.method="spearman",
            combine.fn=stouffer_liptak.combine){
    res = lapply(1:ncol(meth), function(icol){
        lmr(formula, covs, meth[,icol], weights=weights[,icol])
    })  
    pvals = unlist(lapply(1:length(res), function(i){ res[[i]]$p }))
    sigma = cor(meth, use="pairwise.complete.obs")
    combined.p = combine.fn(pvals, sigma)
    coef = mean(unlist(lapply(1:length(res), function(i){ res[[i]]$coef })))
    list(covariate=res[[1]]$covariate, p=combined.p, coef=coef)
}   


# for bumping
permute.residuals = function(mat, mod, mod0, iterations=100, p_samples=1, mc.cores=10, weights=NULL){
    stopifnot(nrow(mod) == ncol(mat))

    reduced_lm = lmFit(mat, mod0, weights=weights)
    reduced_residuals = residuals(reduced_lm, mat)
    reduced_fitted = fitted(reduced_lm)

    fit = lmFit(mat, mod, weights=weights)

    coef.name = setdiff(colnames(mod), colnames(mod0))
    beta.orig = coefficients(fit)[,coef.name]

    rm(reduced_lm, fit); gc()
    nc = ncol(reduced_residuals)

    beta.list = mclapply(1:iterations, function(ix){
        mat_sim = reduced_fitted + reduced_residuals[,sample(1:nc)]
        ifit = lmFit(mat_sim, mod, weights=weights)
        icoef = coefficients(ifit)[,coef.name]
        w = ifit$sigma
        # get names as integer positions:
        names(icoef) = 1:length(icoef)
        names(w) = 1:length(w)
        sum.lowess(icoef, w)
    }, mc.cores=mc.cores)
        
    beta.sum = rep(0, n=iterations)
    for(i in 1:iterations){
        beta.sum[i] = beta.list[[i]]
    }
    beta.sum
}

sum.lowess = function(icoefs, weights, span=0.2){
    if(length(icoefs) < 3){ return(sum(icoefs)) }
    res = try(limma::loessFit(icoefs, as.integer(names(icoefs)),
                              span=span, weights=weights), silent=TRUE)
    if(class(res) == "try-error") return(sum(icoefs))
    return(sum(res$fitted))
}


#' Run a local bump-hunting algorithm
#' 
#' This performs a similar task to the Bump-Hunting algorithm, but here the
#' \code{meth} argument is a putative bump. The residuals of the null model
#' are shuffled added back to the null model and the beta's of that simulated
#' data are repeatedly stored and finally compare to the observed coefficient.
#' Due to the shufflings, this is much slower than the other functions in this
#' package.
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a matrix of correlated data.
#' @param weights optional weights matrix of same shape as meth
#' @param n_sims this is currently used as the minimum number of shuffled data
#'        sets to compare to. If the p-value is low, it will do more shufflings
#' @param mc.cores sent to mclapply for parallelization
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
bumpingr = function(formula, covs, meth, weights=NULL, n_sims=20, mc.cores=1){
    suppressPackageStartupMessages(library('parallel', quietly=TRUE))
    suppressPackageStartupMessages(library("limma", quietly=TRUE))
    covs$methylation = 1 # for formula => model.matrix

    if(is.null(rownames(covs))) rownames(covs) = 1:nrow(covs)
    mod = model.matrix(formula, covs)

    # remove rows where any of the covariates are not complete.
    # because the otherwise mod and meth dont have corresponding shapes.
    keep = NULL
    if(!nrow(mod) == ncol(covs)){
        keep = rownames(covs) %in% rownames(mod)
        covs = covs[keep,]
    }

    covariate = colnames(mod)[1 + as.integer(colnames(mod)[1] == "(Intercept)")]
    mod0 = mod[,!colnames(mod) == covariate, drop=FALSE]
    if((!ncol(meth) == nrow(covs)) && nrow(meth) == nrow(covs)){
        meth = t(meth)
        if(!(is.null(weights))){ weights = t(weights) }
    }
    if(!is.null(keep)){
        meth = meth[,keep]
        if(!is.null(weights)) weights = weights[,keep]
    }

    sim_beta_sums = permute.residuals(meth, mod, mod0, iterations=n_sims, 
                                      mc.cores=mc.cores, weights=weights)
    stopifnot(length(sim_beta_sums) == n_sims)

    fit = lmFit(meth, mod, weights=weights)
    w = fit$sigma

    icoef = coefficients(fit)[,covariate]
    # get names as integer positions:
    names(icoef) = 1:length(icoef)
    names(w) = 1:length(w)
    beta_sum = sum.lowess(icoef, w)

    raw_beta_sum = sum(coefficients(fit)[,covariate])
    ngt = sum(abs(sim_beta_sums) >= abs(beta_sum))
    # progressive monte-carlo: only do lots of sims when it has a low p-value.
    if(ngt < 2 & n_sims == 20) return(bumpingr(formula, covs, meth, n_sims=100, mc.cores=mc.cores))
    if(ngt < 4 & n_sims == 100) return(bumpingr(formula, covs, meth, n_sims=2000, mc.cores=mc.cores))
    if(ngt < 10 & n_sims == 2000) return(bumpingr(formula, covs, meth, n_sims=5000, mc.cores=mc.cores))
    if(ngt < 10 & n_sims == 5000) return(bumpingr(formula, covs, meth, n_sims=15000, mc.cores=mc.cores))
    pval = (1 + ngt) / (1 + n_sims)
    return(list(covariate=covariate, p=pval, coef=raw_beta_sum / nrow(meth)))
}


#' Fit a mixed effect model with lme4 syntax on count data using glmer.nb on
#' count data.
#'
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
nb.mixed.count = function(formula, covs){
    w = options("warn")$warn
    e = options("error")$error
    options(warn=0, error=NULL)
    suppressPackageStartupMessages(library('lme4', quietly=TRUE))
    #s = summary(glmer(formula, covs, family="poisson"))$coefficients
    # glmer.nb doesn't normalize the weights.
    #weights = covs$weights * length(covs$weights) / sum(covs$weights)
    # todo: use offset variable (offset=covs$counts)
    #s = summary(glmer.nb(formula, covs, offset=covs$counts))$coefficients
    s = summary(glmer.nb(formula, covs))$coefficients
    options(warn=w, error=e)
    covariate = paste0(rownames(s)[2], ".nb")
    row = s[2,]
    coef = row[['Estimate']] # invert via ppois?
    list(covariate=covariate, p=row[['Pr(>|z|)']], coef=coef)
}

#' Use Generalized Estimating Equations to assign significance to a cluster
#' of data.
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param idvar idvar sent to \code{geepack::geeglm}
#' @param corstr the corstr sent to \code{geepack::geeglm}
#' @param counts if TRUE, then the poisson family is used.
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
geer = function(formula, covs, idvar="CpG", corstr="ex", counts=FALSE){
    # assume it's already sorted by CpG, then by id.
    if(idvar != "CpG" && corstr == "ar"){
        covs = covs[order(covs[,idvar], covs$CpG),]
    }
    suppressPackageStartupMessages(library('geepack', quietly=TRUE))
    stopifnot(!is.null(idvar))

    # NOTE, both of these are required as geeglm needs to deparse and
    # R CRAN has to make sure clustervar exists.
    clustervar = covs$clustervar = covs[,idvar]
    # can't do logistc with idvar of id, gives bad results for some reason
    if(!is.null(covs$weights)){
        weights = covs$weights / sum(covs$weights) * length(covs$weights)
        s = summary(geeglm(formula, id=clustervar, data=covs, corstr=corstr,
                       family=ifelse(counts, "poisson", "gaussian"),
                       weights=weights))$coefficients
    } else {
        s = summary(geeglm(formula, id=clustervar, data=covs, corstr=corstr,
                           family=ifelse(counts, "poisson", "gaussian")))$coefficients
    }
    covariate = rownames(s)[2]
    row = s[covariate,]
    if(counts) covariate=paste0(covariate, ".poisson")
    return(list(covariate=covariate, p=max(row[['Pr(>|W|)']], 1e-13), coef=row[['Estimate']]))
}

#geer(read.csv('tt.csv'), methylation ~ disease, "id", "ex")

#' Use mixed-effects model in lme4 syntax to associate a covariate with a
#' cluster of data.
#' 
#' An example model would look like:
#'    methylation ~ disease + age + gender + (1|CpG) + (1|id)
#' To determine the associate of disease and methylation and allowing for
#' random intercepts by CpG site and by sample id.
#' 
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param formula an R formula containing "methylation"
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
mixed_modelr = function(formula, covs){
    suppressPackageStartupMessages(library('lme4', quietly=TRUE))
    suppressPackageStartupMessages(library('multcomp', quietly=TRUE))
    # automatically do logit regression.
    m = lmer(formula, covs, weights=covs$weights)
    covariate = names(fixef(m))[1 + as.integer(names(fixef(m))[1] == "(Intercept)")]
    r = ranef(m)
    for(re in names(r)){
        if(length(unique(r[[re]][[1]])) == 1){
            return(list(covariate=covariate, p=1, coef=NaN))
        }
    }
    # take the first column unless it is intercept
    s = summary(glht(m, paste(covariate, "0", sep=" == ")))
    return(list(covariate=covariate, p=s$test$pvalues[[1]], coef=s$test$coefficients[[1]]))
}

#' Use SKAT to associate a covariate with a cluster of data.
#' 
#' An example model would look like:
#'    disease ~ 1
#' And the result would be testing if adding the correlated matrix of
#' data (with all the assumptions of SKAT) improves that null model.
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a matrix of correlated data.
#' @param r.corr list of weights between kernel and rare variant test.
#' @return \code{list(covariate, p, coef)} where p and coef are for the coefficient
#'         of the first term on the RHS of the model.
#' @export
skatr = function(formula, covs, meth, r.corr=c(0.00, 0.015, 0.06, 0.15)){
    suppressPackageStartupMessages(library('SKAT', quietly=TRUE))
    covariate = all.vars(formula)[1]

    capture.output(obj <- SKAT_Null_Model(formula, out_type="D", data=covs))
    #sk <- SKAT(meth, obj, is_check_genotype=FALSE, method="davies", r.corr=0.6, kernel="linear")
    sk <- SKAT(as.matrix(meth), obj, is_check_genotype=FALSE, method="optimal.adj", kernel="linear",
            r.corr=r.corr)
    #sk <- SKAT(meth, obj, is_check_genotype=TRUE, method="optimal.adj", kernel="linear.weighted", weights.beta=c(1, 10))
    #sk <- SKAT(meth, obj, is_check_genotype=TRUE, method="optimal.adj", kernel="linear")
    #sink()
    return(list(covariate=covariate, p=sk$p.value, coef=NaN))
}

#' convert data to long format so that \code{covs} is replicated once for
#' each column in \code{meth}
#'
#' @param covs data.frame of covariates
#' @param meth matrix of methylation with same number of rows as \code{covs}
#' @param weights matrix of weights with same dim as of rows as \code{meth}
#'        or NULL
#' @return long-format data.frame with added columns for 'id', 'methylation'
#'         and 'CpG' (and possibly 'weights').
#'         Has nrow == ncol(meth) * nrow(meth).
#' @export
expand.covs = function(covs, meth, weights=NULL, counts=FALSE){
    if(!"id" %in% colnames(covs)) covs$id = as.factor(1:nrow(covs))
    n_samples = nrow(covs)
    meth = as.matrix(meth)
    stopifnot(nrow(meth) == n_samples)
    # e.g. meth is 68 patients * 4 CpGs
    #      covs is 68 patients * 5 covariates
    # need to replicated covs 4 times (1 per CpG)
    covs = covs[rep(1:nrow(covs), ncol(meth)),, drop=FALSE]
    cpgs = 1:ncol(meth)
    if(!is.null(weights)){
        stopifnot(nrow(weights) == n_samples)
        dim(weights) = NULL
        covs$weights = as.numeric(weights)
        if(counts) covs$counts = covs$weights
    }

    dim(meth) = NULL
    covs$methylation = meth
    covs$CpG = as.factor(rep(cpgs, each=n_samples)) # 1 1 1, 2 2 2, etc since CpG's are grouped.
    covs
}

#' dispatch to one of the implemented cluster methods
#' 
#' For every method except mixed_model, one or more of the arguments
#' must be specified. To run a linear model, simply send the formula
#' in lme4 syntax
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a matrix of correlated data.
#' @param weights matrix of weights with same dim as \code{meth}
#'        or NULL. Used in weighted regression.
#' @param gee.corstr if specified, the the corstr arg to geeglm.
#'        gee.idvar must also be specified.
#' @param gee.idvar if specified, the cluster variable to geeglm
#' @param counts if specified, then use poisson or NB where available
#' @param bumping if true then the bumping algorithm is used.
#' @param combine either "liptak" or "z-score" used to get a single p-value
#'        after running a test on each probe.
#' @param skat use the SKAT method to test associated. In this case, the
#'        model will look like: \code{disease ~ 1} and it will be tested
#'        against the methylation matrix
#' @export
clust.lm = function(formula, covs, meth,
                    weights=NULL,
                    gee.corstr=NULL, gee.idvar=NULL,
                    counts=FALSE,
                    bumping=FALSE,
                    betareg=FALSE,
                    combine=c(NA, "liptak", "z-score"), skat=FALSE){

    formula = as.formula(formula)
    combine = match.arg(combine)

    if(betareg){
        return(betaregr(formula, covs, meth, weights, combine))
    }

    if(ncol(meth) == 1 || is.vector(meth)){
        # just got one column, so we force it to use a linear model
        # remove random effects terms for CpG, id
        #lhs = grep("|", attr(terms(formula), "term.labels"), fixed=TRUE, value=TRUE, invert=TRUE)
        lhs = grep("\\|\\s*id|\\|\\s*CpG", attr(terms(formula), "term.labels"),  value=TRUE, invert=TRUE, perl=TRUE)
        # add the parens back around the term.
        lhs = gsub("(.+\\|.+)", "(\\1)", lhs, perl=TRUE)
        lhs = paste(lhs, collapse=" + ")
        formula = as.formula(paste("methylation", lhs, sep=" ~ "))
        # TODO: handle counts.
        # if removing |id and |CpG is all of the mixed-effect terms, then we can just run linear model.
        if(!any(grep("|", attr(terms(formula), "term.labels"), fixed=TRUE))){
            return(lmr(formula, covs, meth, weights))
        }
    }


    # we assume there is one extra column for each CpG
    rownames(meth) = rownames(covs)

    if(bumping){ # wide
        w = NULL
        if(!is.null(weights)) w=t(weights)
        return(bumpingr(formula, covs, t(meth), weights=w))
    }
    if(skat){ # wide
        return(skatr(formula, covs, meth))
    }
    if(!is.na(combine)){ # wide
        if(combine == "liptak"){
            return(combiner(formula, covs, meth, combine.fn=stouffer_liptak.combine, weights=weights))
        } 
        stopifnot(combine == "z-score")
        return(combiner(formula, covs, meth, combine.fn=zscore.combine, weights=weights))
    }

    ###########################################
    # GEE and mixed models require long format.
    ###########################################
    covs = expand.covs(covs, meth, weights, counts) # TODO: make this send just the nrow, ncol

    is.mixed.model = any(grepl("|", attr(terms(formula), 'term.labels'), fixed=TRUE))
    # mixed-model
    if (is.null(gee.corstr)){
        stopifnot(is.mixed.model)

        if(counts) return(nb.mixed.count(formula, covs))

        return(mixed_modelr(formula, covs))
    # GEE
    } else if (!is.null(gee.corstr)){
        stopifnot(!is.null(gee.idvar))
        return(geer(formula, covs, idvar=gee.idvar, corstr=gee.corstr, counts=counts))
    # limma
    } else {
        # TODO this goes in the matrix section above and uses
        # duplicateCorrelation
        stop()
    }

}

#' used to communicate quickly from python
#' @export
#' @param bin.file file with binary data
read.bin = function(bin.file){
    conn = file(bin.file, 'rb')
    n_sites = readBin(conn, what=integer(), size=8, n=1)
    l = list()
    for(i in 1:n_sites){
        mdims = readBin(conn, what=integer(), size=8, n=2)
        nrow = mdims[1]
        ncol = mdims[2]
        dat = readBin(conn, what=numeric(), size=8, n=nrow * ncol)
        l[[i]] = matrix(dat, nrow=nrow, ncol=ncol, byrow=TRUE)
    }
    close(conn)
    l
}

#' dispatch to one of the implemented cluster methods. potentially reading
#' the covariates from a file and parallelizing.
#' 
#' See \code{\link{clust.lm}}
#' 
#' @param formula an R formula containing "methylation"
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meths a list of matrices of correlated data.
#' @param gee.corstr if specified, the the corstr arg to geeglm.
#' @param mc.cores the number of processors to use if meths is a list of
#'        matrices to test.
#' @param ... arguments sent to \code{\link{clust.lm}}
#' @export
mclust.lm = function(formula, covs, meths, weights=NULL, gee.corstr=NULL, ..., mc.cores=4){
    if(is.character(covs)) covs = read.csv(covs)

    # its a single entry, not list of matrices that we can parallelize
    if(is.matrix(meths) || is.data.frame(meths)){
        res = (clust.lm(formula, covs, meths, gee.corstr=gee.corstr, ...))
        return(data.frame(res))
    }

    suppressPackageStartupMessages(library('data.table', quietly=TRUE))
    suppressPackageStartupMessages(library('parallel', quietly=TRUE))

    cluster_ids = 1:length(meths)
    results = mclapply(cluster_ids, function(cs){
        res = try(clust.lm(formula, covs, meths[[cs]],
                           weights=weights[[cs]], gee.corstr=gee.corstr, ...))
        if(!inherits(res, "try-error")){
            res$cluster_id = cs
            return(res)
        }

        return(list(covariate=NA, p=NaN, coef=NaN, cluster_id=cs))
    }, mc.cores=mc.cores)
    results = rbindlist(results)
    rownames(results) = cluster_ids
    results
}


if(FALSE){
    source('R/combine.R')
    covs = read.delim("inst/extdata/example-covariates.txt")
    covs$id = 1:nrow(covs)
    meth = read.csv('inst/extdata/example-meth.csv', row.names=1)

    #  check with only a single value
    #meth = cbind(meth[,1])
    print(ncol(meth))

    print(mclust.lm(methylation ~ disease + (1|id) + (1|CpG), covs, meth))

    print('liptak')
    print(mclust.lm(methylation ~ disease, covs, meth, combine="liptak"))
    print(mclust.lm(methylation ~ disease, covs, meth, combine="z-score"))

    print(mclust.lm(methylation ~ disease + (1|id), covs, meth,))
    print(mclust.lm(methylation ~ disease, covs, meth, gee.idvar="id", gee.corstr="ex"))
    print(mclust.lm(methylation ~ disease, covs, meth, gee.idvar="id", gee.corstr="ar"))
    print('bumping')
    print(mclust.lm(methylation ~ disease, covs, meth, bumping=TRUE))
    print('sklat')
    print(clust.lm(disease ~ 1, covs, as.matrix(meth), skat=TRUE))
}

#' read a matrix of numeric values with the first column as the row.names
#'
#' @param fname the file name of the Xpression dataset to read.
#' @export
readX = function(fname){
    X = data.matrix(read.delim(gzfile(fname), row.names=1, stringsAsFactors=FALSE, quote=""))
    rownames(X) = gsub("-|:| ", ".", as.character(rownames(X)), perl=TRUE)
    X
} 

#' dispatch to one of the implemented cluster methods. potentially reading
#' the covariates from a file and parallelizing.
#'
#' This method implements a sorted of methyl-eQTL with a formula specified
#' as:
#' 
#'    \code{methylation ~ disease + age}
#'
#' each row in \code{X} is inserted into the model and tested so the model
#' would be:
#'
#'    \code{methylation ~ X[irow,] + disease + age}
#'
#' and the reported coefficent and p-value are from the X[irow,] covariate.
#' This allows one to test a number of expression probes against a (number
#' of) cluster of correlated methylation probes. Though we could also use
#' this to test, for example a set of methylation probes against every OTU
#' in a microbiome study. In this way, we could find DMRs related to the
#' microbiome.
#' 
#' See \code{\link{clust.lm}}
#' 
#' @param covs covariate data.frame containing the terms in formula
#'        except "methylation" which is added automatically
#' @param meth a list of matrices of correlated data or a single methylation
#'        matrix
#' @param formula an R formula containing "methylation"
#' @param X a matrix with columns matching those in meth. n_probes X n_samples.
#'        Each row is tested by modifying \code{formula} so that it becomes the
#'        independent variable in the model and tested against methylation.
#' @param gee.corstr if specified, the the corstr arg to geeglm.
#' @param mc.cores the number of processors to use if meths is a list of
#'        matrices to test.
#' @param ... arguments sent to \code{\link{clust.lm}}
#' @export
mclust.lm.X = function(formula, covs, meth, X, gee.corstr=NULL, ..., mc.cores=4){
    library(parallel)
    library(data.table)
    formula = as.formula(formula)
    if(is.character(covs)) covs = read.csv(covs)

    # if calling repeatedly, should be subsets of the expression matrix that are close to
    # (presumably) the methylation matrix being tested.
    if(!is.matrix(X)){
        X = readX(X)
    }

    mc.cores = min(mc.cores, ncol(X))

    rnames = rownames(X)

    stopifnot(nrow(covs) %% ncol(X) == 0)
    n_each = nrow(covs) / ncol(X)

    # need this for when X_locs is not specified since we never readi
    # in the array in python

    # get a + b + c from y ~ a + b + x
    rhs = as.character(formula)[length(as.character(formula))]
    lhs = as.character(formula)[2]
    irows = 1:nrow(X)
    stopifnot(n_each >= 1)

    results = mclapply(irows, function(irow){
        X.row = rep(t(X[irow,]), n_each)
        covs2 = covs # make a copy so we dont end up with huge covs
        # add the expression column to the dataframe.
        covs2[,rnames[irow]] = X.row
        if(rhs == "1"){ # methylation ~ 1 => methylation ~ probe
            sformula = sprintf("%s ~ %s", lhs, rnames[irow])
        } else {
            sformula = sprintf("%s ~ %s + %s", lhs, rnames[irow], rhs)
        }
        # call with 1 core since we're already parallel here.
        res = mclust.lm(as.formula(sformula), covs2, meth,
                           gee.corstr=gee.corstr, ..., mc.cores=1)
        res$X = rnames[irow]
        res$model = sformula
        res
    }, mc.cores=mc.cores)
    rbindlist(results)
}

cprint = function(...) write(..., stdout())

#' generate correlated data
#'
#' @param rho numeric correlation value between 0 and 1
#' @param n_samples generate data for this many samples
#' @param n_sites generate data for this many sites (CpGs)
#' @param mean vector of length \code{n_samples} added to the generated data.
#' @param sd sent to \code{rnorm}
#' @return mat n_samples * n_sites matrix where \code{cor(mat[,1], mat[,2])} is
#'         on average equal to \code{rho}
#' @export
gen.correlated = function(rho, n_samples=100, n_sites=4, mean=0, sd=1){
    X = matrix(rnorm(n_samples * n_sites, mean=0, sd=sd), nrow=n_samples)
    X = make.correlated(rho, X)
    sweep(X, 1, mean, "+")
}

#' make existing data correlated
#'
#' @param rho numeric correlation value between 0 and 1
#' @param X n_samples * n_probes data to make correlated
#' @return mat n_samples * n_sites matrix where \code{cor(mat[,1], mat[,2])} is
#'         on average equal to \code{rho}
#' @export
make.correlated = function(rho, X){
    sigma = diag(ncol(X))
    sigma = rho ^ abs(row(sigma) - col(sigma))
    X %*% chol(sigma)
}


test_X = function(){
    covs = read.delim("clustercorr/tests/example-covariates.txt")
    covs$id = 1:nrow(covs)
    meth = read.csv('clustercorr/tests/example-meth.csv', row.names=1)
    #covs = covs[covs$cluster_set == 1,]
    X = read.delim(gzfile('clustercorr/tests/example-expression.txt.gz'), row.names=1)

    cprint("\nmixed-effects model")
    formula = methylation ~ disease + (1|id) + (1|CpG)
    df = mclust.lm.X(covs, meth, formula, X, testing=TRUE)
    print(head(df[order(as.numeric(df$p)),], n=5))

    cprint("\nGEE")
    formula = methylation ~ disease #+ (1|id) + (1|CpG)
    df = mclust.lm.X(covs, meth, formula, X, testing=TRUE, gee.corstr="ar", gee.idvar="id")
    print(head(df[order(as.numeric(df$p)),], n=5))

    cprint("\nbumping")
    formula = methylation ~ disease #+ (1|id) + (1|CpG)
    df = mclust.lm.X(covs, meth, formula, X, testing=TRUE, bumping=TRUE)
    print(head(df[order(as.numeric(df$p)),], n=5))

    cprint("\nliptak")
    formula = methylation ~ disease #+ (1|id) + (1|CpG)
    dfl = mclust.lm.X(covs, meth, formula, X, testing=TRUE, liptak=TRUE)
    print(head(dfl[order(dfl$p),], n=5))
    print(dfl[dfl$covariate == "A_33_P3403576",])

    # show that we get the same result (about with the linear model)
    # pvalue is  2.85844757130782e-06 for the clustered approach and
    # 7.88e-07 for looking at a single probe with a linear model in
    # the region. coefficients vary by ~ 0.001.
    probe = "A_33_P3403576"
    covs$X = t(X[probe,])
    ests = c()
    for(cname in colnames(meth)){
        covs$methylation = meth[,cname]
        cprint(paste0("\n", probe))
        s = summary(lm(methylation ~ X + disease, covs))$coefficients
        print(s)
        ests = c(ests, s['X', 'Estimate'])
    }
    print(mean(ests))

}
#test_X()

