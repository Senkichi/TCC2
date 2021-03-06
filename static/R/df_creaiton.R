setwd('D:/Programs/GitHub/TCC2/static/data')

require(devtools)
require(OpenIMBCR)
require(rgdal)
require(tidyverse)
require(vegan)
require(sp)
require(data.table)
require(rlang)

require(raster)
require(rgeos)
require(tcltk)
require(parallel)
require(sqldf)
require(doParallel)
require(xml2)
require(rvest)
require(foreign)
require(BrotherOrange)
require(curl)

removeTmpFiles(h=0)


grep_by <- function(x, pattern=NULL){
  x[grepl(as.character(x), pattern = pattern)]
}
#' hidden function that grabs all "<a href" patterns in an HTML node tree
parse_hrefs <- function(url=NULL){
  return(as.character(rvest::html_nodes(
    xml2::read_html(url), "a"
  )))
}

parse_url <- function(x=NULL){
  return(unlist(lapply(
    strsplit(x, split = "\""),
    FUN = function(x) x[which(grepl(x, pattern = "zip$"))]
  )))
}

#' web scraping interface that parses out full-path URL's for 30 arc-second
#' (900m) worldclim data.
#' @export
scrape_worldclim <- function(base_urls= c("http://worldclim.org/cmip5_30s", 'http://www.worldclim.org/cmip5_10m', 'http://www.worldclim.org/cmip5_5m', 'http://www.worldclim.org/cmip5_2.5m'),
                             models=NULL, # two-letter codes for CMIP model
                             climate=FALSE,
                             bioclim=FALSE,
                             start_of_century=FALSE,
                             mid_century=FALSE,
                             end_of_century=FALSE,
                             scen_45=FALSE,
                             scen_85=FALSE,
                             res=NULL,
                             formats="bi"
){
  # fetch and parse index.html
  if (!is.null(res)){
    base_urls <- grep_by(base_urls, pattern = paste(res, collapse = '|'))
  }
  hrefs_future <- vector()
  hrefs_future <- append(hrefs_future, unlist(lapply(base_urls, FUN = parse_hrefs)))
  hrefs_current <- parse_hrefs("http://worldclim.org/current")
  hrefs_final <- vector() # "final" URL's fetch-list
  # greppable user parameters for models to fetch
  time_periods <- vector()
  climate_sets <- vector()
  scenarios    <- vector()
  resolutions  <- res
  # grep across time aggregations (handle "current" last, it is it's own query)
  if (start_of_century){
    time_periods <- append(time_periods,"cur")
  }
  if (mid_century){
    time_periods <- append(time_periods,"50[.]zip")
  }
  if (end_of_century){
    time_periods <- append(time_periods,"70[.]zip")
  }
  hrefs_future <- grep_by(
    hrefs_future,
    pattern = paste(time_periods, collapse = "|")
  )
  # grep across raw climate / bioclim
  if (bioclim){
    climate_sets <- append(climate_sets, "bi.[0-9]")
  }
  if (climate){
    # not implemented -- do some digging
    climate_sets <- append(climate_sets, "tn.[0-9]")
  }
  hrefs_future <- grep_by(
    hrefs_future,
    pattern = paste(climate_sets, collapse = "|")
  )
  # grep across emissions scenarios
  if (scen_45){
    scenarios <- append(scenarios,"/..45")
  }
  if (scen_85){
    scenarios <- append(scenarios,"/..85")
  }
  if(length(scenarios)==0){
    hrefs_future <- grep_by(
      hrefs_future,
      pattern = "cur"
    )
  } else {
    hrefs_future <- grep_by(
      hrefs_future,
      pattern = paste(scenarios, collapse = "|")
    )
  }
  # assume our hrefs into hrefs_final and check for "current" hrefs, if needed
  hrefs_final <- hrefs_future
  
  # grep across resolutions
  if(!is.null(resolutions)){
    hrefs_final <- grep_by(
      hrefs_final,
      pattern = paste(resolutions, collapse = "|")
    )
    hrefs_current <- grep_by(
      hrefs_current,
      pattern = paste(resolutions, collapse = '|')
    )
  }
  # grep across file formats - temporarily disabled, not working as intended
  #if (!is.null(formats)){
  # hrefs_final <- grep_by(
  #   hrefs_final,
  #  pattern = paste(
  #  paste(formats, str_extract_all(time_periods, pattern = "[[0-9]]{2}") ,".zip", sep = ""),
  #  collapse = "|"
  #   )
  # )
  #}
  # grep across GCMs
  if (!is.null(models[1])){
    hrefs_final <- grep_by(
      hrefs_final,
      pattern = paste(paste("/", tolower(models), sep = ""), collapse = "[0-9]|")
    )
  } else if (is.null(models)){
    warning("no CMIP5 models specified by user")
  }
  
  # append "current" climate if it was requested
  if (start_of_century){
    # append bioclim and/or original climate variables to final fetch-list
    if (bioclim){
      hrefs_final <- append(
        hrefs_final,
        grep_by(hrefs_current, pattern = "/bio_.+?bil")
      )
    }
    if (climate){
      hrefs_final <- append(
        hrefs_final,
        grep_by(hrefs_current,
                pattern ="/tmax.[0-9]|/tmean.[0-9]|/tmin.[0-9]|/prec_")
      )
    }
  }
  # return URLs to user
  return(unlist(lapply(hrefs_final, FUN = parse_url)))
}

#' fetch and unpack missing worldclim climate data
#' @export
worldclim_fetch_and_unpack <- function(urls=NULL, exdir="climate_data", resolution = NULL, time = FALSE){
  if(!dir.exists(exdir)){
    dir.create(exdir)
  }
  existing_files <- list.files(exdir, full.names=T)
  climate_zips <- unlist(lapply(
    strsplit(urls,split="/"),
    FUN = function(x) return(x[length(x)])
  ))
  #allows for the parsing of multiple resolutions at once
  if (!is.null(resolution)) {
    plus_resolution <- paste(
      unlist(lapply(
        strsplit(urls,split="/"),
        FUN = function(x) return(x[length(x) - 1])
      )),
      unlist(lapply(
        strsplit(urls,split="/"),
        FUN = function(x) return(x[length(x)])
      )),
      sep = '_'
    )
    resolution_search <- paste(
      'cmip5',
      unlist(lapply(
        strsplit(urls,split="/"),
        FUN = function(x) return(x[length(x) - 1])
      )),
      unlist(lapply(
        strsplit(urls,split="/"),
        FUN = function(x) return(x[length(x)])
      )),
      sep = '/'
    )
    #most of this convoluted code allows for the searching and saving of differing resolutions with similar link endings
    resolution_search <- resolution_search[grep(resolution_search, pattern = 'cur', invert = T)]
    plus_resolution <- plus_resolution[(grep(plus_resolution, pattern = 'cur', invert = T))]
  }
  if(sum(grepl(existing_files, pattern=paste(climate_zips,collapse="|")) ) != length(climate_zips) ){
    cat(" -- fetching missing climate data\n")
    # strip the existing files so we only match against the filename
    fn_existing_files <- unlist(lapply(strsplit(
      existing_files,
      split="/"
    ),
    FUN=function(x) return(x[length(x)])
    ))
    if (!is.null(resolution)){
      missing_files <- which(!(climate_zips %in% fn_existing_files))
      missing_res <- which(!(plus_resolution %in% fn_existing_files))
      res_urls <- c()
      for (i in missing_res){
        res_urls[i] <- resolution_search[i]
      }
      res_urls <- urls[grep(urls, pattern = paste(res_urls, collapse = '|'))]
      res_final <- append(res_urls, urls[missing_files])
      redundant_zips <- unlist(lapply(
        strsplit(res_final,split="/"),
        FUN = function(x) return(x[length(x)])
      ))
      #check missin files for files with the plus_res names, and replace then with correct links from res_search
      for(i in length(res_final)){
        if (i <= length(res_urls)){
          download.file(
            res_final[i],
            destfile=file.path(paste(
              exdir,
              plus_resolution[missing_res[i]],
              sep = "/")
            )
          )
        } else {
          download.file(
            res_final[i],
            destfile=file.path(paste(
              exdir,
              redundant_zips[i],
              sep = "/")
            )
          )
        }
      }
    } else {
      missing_files <- which(!(climate_zips %in% fn_existing_files))
      
      for(i in missing_files){
        download.file(
          urls[i],
          destfile=file.path(paste(
            exdir,
            climate_zips[i],
            sep = "/")
          )
        )
      }
    }
  }
  # check for existing rasters in exdir and unpack if none found
  # also check zips against existing raster files, unpack zips which haven't beeen unpacked
  existing_files <- list.files(exdir, pattern="bil$|tif$")
  existing_zips <- list.files(exdir, pattern="zip$")
  already_unzipped <- grep_by(existing_zips, pattern = "^^[^_|[0-0]]+")
  if (sum(length(existing_zips)) != sum(length(already_unzipped))) {
    cat(" -- unpacking climate data\n")
    for(i in existing_zips[!(existing_zips %in% already_unzipped)]){
      unzip(file.path(
        paste(paste(getwd(), exdir, sep = "/"),
              i,
              sep="/")
      ),
      exdir=paste(getwd(),
                  exdir,
                  sep = "/")
      )
    }
  } else {
    warning("found existing rasters in the exdir -- leaving existing files")
  }
}

#' return a RasterStack of worldclim data, parsed by flags and/or pattern
#' @export
build_worldclim_stack <- function(vars=NULL,
                                  time=NULL,
                                  bioclim=F,
                                  climate=F,
                                  pattern=NULL,
                                  bounding=NULL){
  all_vars <- list.files(
    paste(getwd(),"climate_data", sep = "/"),
    pattern="bil$|tif$",
    full.names=T
  )
  climate_flags <- vector()
  if(grepl(tolower(time), pattern="cur")){
    # current climate data are always .bil files
    all_vars <- grep_by(all_vars, pattern="bil$")
  } else if(grepl(as.character(time),pattern="50")){
    all_vars <- grep_by(all_vars, pattern=".50.")
  } else if(grepl(as.character(time),pattern="70")){
    all_vars <- grep_by(all_vars, pattern=".70.")
  }
  if(bioclim){
    climate_flags <- append(climate_flags,"bi")
  }
  if(climate){
    climate_flags <- append(climate_flags,"tm.*._|prec")
  }
  
  all_vars <- grep_by(
    all_vars,
    pattern=paste(climate_flags, collapse = "|")
  )
  
  if (!is.null(vars)){
    # parse out weird worldclim var formating (differs by time scenario)
    if(grepl(tolower(time), pattern="cur")){
      v <- unlist(lapply(
        strsplit(all_vars,split="/"),
        FUN=function(x) x[length(x)]
      ))
      v <- lapply(
        strsplit(v,split="_"),
        FUN=function(x) x[length(x)]
      )
      v <- as.numeric(gsub(
        v,
        pattern = ".bil",
        replacement = ""
      ))
      all_vars <- all_vars[ v %in% vars ]
    } else if (grepl(tolower(time), pattern = "50|70")){
      split <- gsub(as.character(time), pattern = "20", replacement = "")
      v <- unlist(lapply(
        strsplit(all_vars, split = "/"),
        FUN = function(x) x[length(x)]
      ))
      v <- lapply(
        strsplit(v,split=split),
        FUN=function(x) x[length(x)]
      )
      v <- as.numeric(gsub(v, pattern=".tif", replacement = ""))
      all_vars <- all_vars[ v %in% vars ]
    }
  }
  # any final custom grep strings passed?
  if(!is.null(pattern)){
    all_vars <- grep_by(all_vars, pattern=pattern)
  }
  # stack and sort our variables before returning the stack to the user
  all_vars <- raster::stack(all_vars)
  if(!is.null(bounding)){
    all_vars <- crop(all_vars, extent(bounding))
  }
  heuristic <- function(x){
    sum(which(letters %in% unlist(strsplit(x[1], split="")))) +
      as.numeric(x[2])
  }
  return(
    all_vars[[
      names(all_vars)[
        order(unlist(lapply(
          strsplit(names(all_vars), split="_"),
          FUN=heuristic)
        ))
        ]
      ]]
  )
}


# read in fire data, currently as polugons of the fire boundaries with associated data
fire <- readOGR('../data/Wildfires_1870_2015_Great_Basin_SHAPEFILE/Wildfires_1870_2015_Great_Basin.shp')


#create a bounding box of the area of the fire dataset, to trim down the wordclim dataset later
fire_extent <- raster::extent(fire)

#turn that bounding box into a polygon
fire_extent <- as(
  fire_extent,
  'SpatialPolygons'
)


#selects only the fire data of years we are interested in
fire_century <- fire[fire@data[,'Fire_Year'] > 1970,]

#assign value of 1 to all polygons, which we will use as the presence/absence responce variable
fire_century@data[, 'presence'] <- 1

#make sure geographic proections are consistent between files
fire_century <- spTransform(fire_century, CRS("+proj=longlat +ellps=WGS84 +towgs84=0,0,0,0,0,0,0 +no_defs"))

proj4string(fire_extent) <- CRS("+proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=23 +lon_0=-96 +x_0=0 +y_0=0 +datum=NAD83 +units=m +no_defs +ellps=GRS80 +towgs84=0,0,0")

fire_extent <- spTransform(fire_extent, CRS("+proj=longlat +ellps=WGS84 +towgs84=0,0,0,0,0,0,0 +no_defs"))

#get worldclim data
worldclim_fetch_and_unpack(urls = scrape_worldclim(
  bioclim=T,
  start_of_century = T,
  mid_century = T,
  end_of_century = T,
  scen_45 = T,
  scen_85 = T,
  models = "BC",
  res = c('10m', '5m', '2-5m')
))

#get worldclim data for the current dataset
worldclim <- raster::crop(
  build_worldclim_stack(bioclim = T, time = "cur"),
  fire_extent)

#convert fire polygons to raster file, spatially consistent with worldclim
fire_raster <- raster::rasterize(
  fire_century,
  future_worldclim,
  field=c('presence')
)

#change na values to zero
fire_raster[is.na(fire_raster)] <- 0

#create a layer of centerpoints for each raster pixel, we will use these points to extract the data
#values from each stacked raster layer underneath each point to create the final dataframe
fire_points <- raster::rasterToPoints(fire_raster, spatial=T)

#extract fire data and coordinates as a n length list of 1/0 values for the n pixels 
raster_frame <- raster::extract(fire_raster, fire_points)

raster_frame <- cbind(fire_points@coords, raster_frame)

#extract worldclim data into its own frame at the same points, then bind the fire frame and the worldclim frame together
#For analysis
worldclim_frame <- raster::extract(worldclim, fire_points)
  worldclim_frame <- cbind(worldclim_frame, raster_frame)

#export file
write.csv(worldclim_frame, 'bio_vars_frame.csv')  


#create dataframes for the future worldclim variables over the US

#create rough bounding box since land boundary cropping takes forever
us_extent <- raster::extent(
  -124.7844079,
  -66.9513812,
  24.7433195,
  49.3457868
)
us_extent <- as(
  us_extent,
  'SpatialPolygons'
)

raster::projection(us_extent) <-
  sp::CRS(raster::projection("+init=epsg:4326"))

#Function for the creation of 


#Looping through future frame creation
for (i in resolutions){
  for (j in eras){
    #Get worldclim data for the future dataset
    future_worldclim <- build_worldclim_stack(bioclim = T, time = '50', pattern = '45')
    future_worldclim <- crop(future_worldclim, us_extent, filename = 'future_worldclim', overwrite = T)
    
    
    #create a layer of centerpoints for each raster pixel, we will use these points to extract the data
    #values from each stacked raster layer underneath each point to create the final dataframe
    future_points <- raster::rasterToPoints(future_worldclim, spatial=T, filename = 'future_points', overwrite = T)
    
    #extract future data and coordinates as a n length list for the n pixels, and bind to list of coordinates
    future_frame <- raster::extract(future_worldclim, future_points)
    
    future_frame <- cbind(future_points@coords, future_frame)
    
    
    write.csv(future_frame, '2070_rcp45_bc_frame.csv')
  }
}


