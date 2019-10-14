---
-- NEB class
-- @classmod NEB

local m = require "math"
local mc = require "flos.middleclass.middleclass"

local array = require "flos.num"
local ferror = require "flos.error"
local error = ferror.floserr

-- Create the NEB class (inheriting the Optimizer construct)
local NEB = mc.class("NEB")

--- Instantiating a new `NEB` object.
--
-- For the `NEB` object it is important to pass the images, and _then_ all
-- the NEB settings as named arguments in a table.
--
-- The `NEB` object implements a generic NEB algorithm as detailed in:
--  1. "Improved tangent estimate in the nudged elastic band method for finding minimum energy paths and saddle points", Henkelman & Jonsson, JCP (113), 2000
--  2. "A climbing image nudged elastic band method for finding saddle points and minimum energy paths", Henkelman, Uberuaga, & Jonsson, JCP (113), 2000
--
-- This particular implementation has been tested and initially developed by Jesper T. Rasmussen, DTU Nanotech, 2016.
--
-- When instantiating a new `NEB` calculator one _must_ populate the initial, all intermediate images and a final image in a a table.
-- The easiest way to do this can be seen in the below usage field.
--
-- To perform the NEB calculation all images (besides the initial and final) are
-- relaxed by an external relaxation method (see `Optimizer` and its child classes).
-- Due to the forces being highly non-linear as the NEB algorithm updates the
-- forces depending on the nearest images, it is adviced to use an MD-like relaxation
-- method such as `FIRE`. If one uses history based relaxation methods (`LBFGS`, `CG`, etc.) one should
-- limit the number of history steps used.
--
-- @usage
-- -- Read in the images
-- -- Note that `read_geom` must be a function that you define to read in the
-- -- atomic coordinates of a corresponding `.xyz` file.
-- images = {}
-- for i = 0, n_images + 1 do
--    images[#images+1] = flos.MDStep{R=read_geom(image_label .. i .. ".xyz")}
-- end
-- neb = NEB(images, {<field1 = value>, <field2 = value>})
-- relax = {}
-- for i = 1, neb.n_images do
--    relax[i] = flos.FIRE()
-- end
-- neb[0]:set(F=<initial-forces>, E=<initial-E>)
-- neb[neb.n_images+1]:set(F=<final-forces>, E=<final-E>)
-- while true do
--    -- Calculate all forces and energies of each image
--    for i = 1, neb.n_images do
--       neb[i]:set(F=<forces>, E=<energy>)
--    end
--    -- Calculate new positions (this must be done after
--    -- the force calculations because the coordinates depend on the
--    -- neighbouring image forces)
--    R = {}
--    for i = 1, neb.n_images do
--       f = neb:force(i)
--       R[i] = relax:optimize(neb[i].R, neb:force(i))
--    end
--    for i = 1, neb.n_images do
--       neb:set(R=R[i])
--    end
-- end
--
-- @function NEB:new
-- @tparam table images all images (starting with the initial, and ending with the final)
-- @tparam[opt=5.] ?number|table k spring constant between the images, a table can be used for individual spring constants
-- @number[opt=5] climbing after this number of iterations the climbing image will be taken into account (to disable climbing, pass `false`)
-- @number[opt=0.005] climbing_tol the tolerance for determining whether an image is climbing or not
local function doc_function()
end
-- Initialization routine
function NEB:initialize(images,tbl)
   -- Convert the remaining arguments to a table
   local tbl = tbl or {}
   --local vectors={}
   --local vc_image={}
   --self.vectors=vectors
   --self.vc_image=images
   --self.vc_image=images[1]
   --self.vc_image.insert(1)
   --for k,v in pairs(vectors) do table.insert(self.vc_image, v) end
     -- Copy all images over
   local size_img = #images[1].R
   for i = 1, #images do
      self[i-1] = images[i]
      self.zeros=images[i].R- images[i].R
      if #images[i].R ~= size_img then
	 error("NEB: images does not have same size of geometries!")
      end
   end
   -- store the number of images (without the initial and final)
   self.n_images = #images - 2
   -- This is _bad_ practice, however,
   -- the middleclass system does not easily enable overwriting
   -- the __index function (because it uses it)
   self.initial = images[1]
   self.final = images[#images]
   --self.neb_type = "TDCINEB" --working
   self.neb_type ="VCCINEB"
   self.DM_label="MgO-3x3x1-2V"
   -- For Adding Temperature Dependet
   self.neb_temp=650.0
   self.boltzman=8.617333262*10^(-5)
   self.beta=1.0/(self.neb_temp*self.boltzman)
   --self.old_DM_label=""
   --self.current_DM_label=""
      -- an integer that describes when the climbing image
   -- may be used, make large enough to never set it
   local cl = tbl.climbing or 5
   if cl == false then
      self._climbing = 1000000000000
   elseif cl == true then
      -- We use the default value
      self._climbing = 5
   else
      -- Counter for climbing
      self._climbing = cl
   end
   -- Set the climbing energy tolerance
   self.climbing_tol = tbl.climbing_tol or 0.005 -- if the input is in eV/Ang this is 5 meV
   self.niter = 0
   -- One should also attach the spring-constant
   -- It currently defaults to 5
   local kl = tbl.k or 10
   if type(kl) == "table" then
      self.k = kl
   else
      self.k = setmetatable({},
			    {
			       __index = function(t, k)
				  return kl
			       end
			    })
   end
   self:init_files()   
end

-- Simple wrapper for checking the image number
function NEB:_check_image(image,all)
   local all = all or false
   if all then
      if image < 0 or self.n_images + 1 < image then
	 error("NEB: requesting a non-existing image!")
      end
    --  if image_vector < 0 or self.n_images + 1 < image_vector then
	 --error("NEB: requesting a non-existing image!")
   --   end
   else
      if image < 1 or self.n_images < image then
	 error("NEB: requesting a non-existing image!")
      end
    --  if image_vector < 1 or self.n_images < image_vector then
	 --error("NEB: requesting a non-existing image!")
    --  end
   end
end


--- Return the coordinate difference between two images
-- @int img1 the first image
-- @int img2 the second image
-- @return `NEB[img2].R - NEB[img1].R`
function NEB:dR(img1, img2)
   self:_check_image(img1, true)
   self:_check_image(img2, true)
   -- This function assumes the reference
   -- image is checked in the parent function
   return self[img2].R - self[img1].R
end

--- Calculate the tangent of a given image
-- @int image the image to calculate the tangent of
-- @return tangent force
function NEB:tangent(image)
   self:_check_image(image)
   -- Determine energies of relevant images
   local E_prev = self[image-1].E
   local E_this = self[image].E
   local E_next = self[image+1].E
   -- Determine position differences
   local dR_prev = self:dR(image-1, image)
   local dR_next = self:dR(image, image+1)
   local dR_this = self:dR(image, image)
   -- Returned value
   local tangent
   -- Determine relevant energy scenario
   --if dR_next:norm(0) == 0.0 or dR_prev:norm(0)==0.0 or dR_this:norm(0)==0.0  then
   --   tangent = dR_this
   --   return tangent
   if E_next > E_this and E_this > E_prev then
      tangent = dR_next
      if dR_next:norm(0) == 0.0  then
        return tangent
      else
        return tangent / tangent:norm(0)
      end
   elseif E_next < E_this and E_this < E_prev then      
      tangent = dR_prev
      if dR_prev:norm(0)==0.0 then
        return tangent
      else
        return tangent / tangent:norm(0)
      end   
   else      
      -- We are at extremum, so mix
      local dEmax = m.max( m.abs(E_next - E_this), m.abs(E_prev - E_this) )
      local dEmin = m.min( m.abs(E_next - E_this), m.abs(E_prev - E_this) )      
      if E_next > E_prev then
         tangent = dR_next * dEmax + dR_prev * dEmin
         if dR_next:norm(0) == 0.0 or dR_prev:norm(0)==0.0 then
             return tangent
         else
         return tangent / tangent:norm(0)
         end
      else
	       tangent = dR_next * dEmin + dR_prev * dEmax
         if dR_next:norm(0) == 0.0 or dR_prev:norm(0)==0.0 then
             return tangent
         else
             return tangent / tangent:norm(0)
         end      
      end      
   end
   -- At this point we have a tangent,
   -- now normalize and return it
   
      --return tangent / tangent:norm(0)
   --end
end
--- Determine whether the queried image is climbing
-- @int image image queried
-- @return true if the image is climbing
function NEB:climbing(image)
   self:_check_image(image)   
   -- Determine energies of relevant images
   local E_prev = self[image-1].E
   local E_this = self[image  ].E
   local E_next = self[image+1].E
   -- Assert the tolerance is taken into consideration
   return (E_this - E_prev > self.climbing_tol) and
       (E_this - E_next > self.climbing_tol)   
end
--- Calculate the spring force of a given image
-- @int image the image to calculate the spring force of
-- @return spring force
function NEB:spring_force(image)
   self:_check_image(image)
   -- Determine position norms
   local dR_prev = self:dR(image-1, image):norm(0)
   local dR_next = self:dR(image, image+1):norm(0)   
   -- Set spring force as F = k (R1-R2) * tangent
   --if dR_prev==0.0 or dR_next==0.0 then
   --  return self:tangent(image) --self.k[image] * (dR_next - dR_prev) * self:tangent(image)
   --else
    return self.k[image] * (dR_next - dR_prev) * self:tangent(image)  
   --end
end
--- Calculate the perpendicular force of a given image
-- @int image the image to calculate the perpendicular force of
-- @return perpendicular force
function NEB:perpendicular_force(image)
   self:_check_image(image)
   if self:tangent(image):norm(0)==0.0 then
     return self[image].F
   else
   -- Subtract the force projected onto the tangent to get the perpendicular force
   local P = self[image].F:project(self:tangent(image))
   return self[image].F - P --self:tangent(image) 
   end
end
--- Calculate the curvature of the force with regards to the tangent
-- @int image the image to calculate the curvature of
-- @return curvature
function NEB:curvature(image)
   self:_check_image(image)
   local tangent = self:tangent(image)
   -- Return the scalar projection of F onto the tangent (in this case the
   -- tangent is already normalized so no need to no a normalization)
   return self[image].F:flatdot(tangent)   
end
-- Calculation of Curvature_k for Temperature Dependent 
--function NEB:curvature_k(image)
--	self:_check_image(image)
--	local k=acos(dot(self:tangent(image-1),self:tangent(image+1)))/(self:dR(image,image-1)+self:dR(image+1,image))
--	return k
--end



-- Calculation of Normal n for Temperature Dependent 
--function NEB:normal(image)
--     self:_check_image(image)
--     local N=self[image].R:project(self:tangent(image)) -- -self:tangant(image):project(self:tangent(image))
--     return self[image].R - N
--	local N=self:dR(image+1,image-1):project(self:tangent(image))
--	return self:dR(image+1,image-1)-N/self:dR(image+1,image-1)-N:norm(0)
--end

--- Calculate the resulting NEB force of a given image
-- @int image the image to calculate the NEB force of
-- @return NEB force

function NEB:neb_force(image)
   self:_check_image(image)
   local NEB_F
   local DNEB_F
   local TDNEB_F
   -- Only run Climbing image after a certain amount of steps (robustness)
   -- Typically this number is 5.
   if self.neb_type == "NEB" then
     if self.niter > self._climbing and self:climbing(image) then
       local F = self[image].F
       NEB_F = F - 2 * F:project( self:tangent(image) )
     else
       DNEB_F = 0.0
       NEB_F = self:perpendicular_force(image) + self:spring_force(image) + DNEB_F
     end
     return NEB_F
   end
   if self.neb_type == "DNEB" then
     if self.niter > self._climbing and self:climbing(image) then
       local F = self[image].F
       if self:tangent(image):norm(0)==0.0 then
           NEB_F = F
       else 
           NEB_F = F - 2 * F:project( self:tangent(image) )
       end
     else
       DNEB_F = self:perpendicular_spring_force(image)-self:perpendicular_spring_force(image):project(self:perpendicular_force(image))*(self:perpendicular_force(image))
       NEB_F = self:perpendicular_force(image) + self:spring_force(image) + DNEB_F--+ self:perpendicular_spring_force(image)-self:perpendicular_spring_force(image):project(self:perpendicular_force(image))*(self:perpendicular_force(image))  --+DNEB_F 
       --print (DNEB_F)
     end
     return NEB_F 
   end
   --===================================================================
   --Adding Temperature Dependent CI-NEB
   --===================================================================
   if self.neb_type == "TDCINEB" then
     if self.niter > self._climbing and self:climbing(image) then
          local F = self[image].F
          if self:tangent(image):norm(0)==0.0 then
               NEB_F = F
          else 
               NEB_F = F - 2 * F:project( self:tangent(image) )
          end
     else
          TDNEB_F = self:perpendicular_force(image)-(self:curvature(image)/self.beta) 
          NEB_F = TDNEB_F + self:spring_force(image) 
     end
     return NEB_F
   end
   --===================================================================
   --Adding Temperature Dependent NEB
   --===================================================================
   
   if self.neb_type == "TDNEB" then
		TDNEB_F = self:perpendicular_force(image)-(self:curvature(image)/self.beta) 
		NEB_F = TDNEB_F + self:spring_force(image) --self:curvature(image) - TDNEB_F 

		return NEB_F
   end
end

--- Query the current coordinates of an image
-- @int image the image
-- @return coordinates
function NEB:R(image)
   self:_check_image(image, true)
   return NEB[image].R
end
--- Query the current force (same as `NEB:force` but with IO included)
-- @int image the image
-- @return force
function NEB:force(image, IO)
   self:_check_image(image)   
   if image == 1 then
      -- Increment step-counter
      self.niter = self.niter + 1
   end
   local F = self[image].F
   local tangent = self:tangent(image)
   local perp_F = self:perpendicular_force(image)
   local spring_F = self:spring_force(image)
   local NEB_F = self:neb_force(image)
    -- Things I want to output in files as control (all in 3xN format)
   if IO then
      local f
      -- Current coordinates (ie .R)
      f = io.open( ("NEB.%d.R"):format(image), "a")
      self[image].R:savetxt(f)
      f:close()
      -- Forces before (ie .F)
      f = io.open( ("NEB.%d.F"):format(image), "a")
      F:savetxt(f)
      f:close()
      -- Perpendicular force
      f = io.open( ("NEB.%d.F.P"):format(image), "a")
      perp_F:savetxt(f)
      f:close()      
      -- Spring force
      f = io.open( ("NEB.%d.F.S"):format(image), "a")
      spring_F:savetxt(f)
      f:close()
      -- NEB Force
      f = io.open( ("NEB.%d.F.NEB"):format(image), "a")
      NEB_F:savetxt(f)
      f:close()
      -- Tangent
      f = io.open( ("NEB.%d.T"):format(image), "a")
      tangent:savetxt(f)
      f:close()
      -- dR - previous reaction coordinate
      f = io.open( ("NEB.%d.dR_prev"):format(image), "a")
      self:dR(image-1, image):savetxt(f)
      f:close()
      -- dR - next reaction coordinate
      f = io.open( ("NEB.%d.dR_next"):format(image), "a")
      self:dR(image, image+1):savetxt(f)
      f:close()
   end
   -- Fake return to test
   return NEB_F   
end
--- Store the current step of the NEB iteration with the appropriate results
function NEB:save(IO)
   -- If we should not do IO, return immediately
   if not IO then
      return
   end
   -- local E0
   local E0 = self[0].E
   -- Now setup the matrix to write the NEB-results
   local dat = array.Array( self.n_images + 2, 6)
   for i = 0, self.n_images + 1 do
      local row = dat[i+1]
      -- image number (0 for initial, n_images + 1 for final)
      row[1] = i
      -- Accumulated reaction coordinate
      if i == 0 then
	 row[2] = 0.
      else
	 row[2] = dat[i][2] + self:dR(i-1, i):norm(0)
      end
      -- Total energy of current iteration
      row[3] = self[i].E
      -- Energy difference from initial image
      row[4] = self[i].E - E0
      -- Image curvature
      if i == 0 or i == self.n_images + 1 then
	 row[5] = 0.
      else
	 row[5] = self:curvature(i)
      end
      -- Vector-norm of maximum force of the NEB-force
      if i == 0 or i == self.n_images + 1 then
	 row[6] = 0.
      else
	 row[6] = self:neb_force(i):norm():max()
      end
   end
   local f = io.open("NEB.results", "a")
   dat:savetxt(f)
   f:close()
end

--- Initialize all files that will be written to
function NEB:init_files()   
   -- We clean all image data for a new run
   local function new_file(fname, ...)
      local f = io.open(fname, 'w')
      local a = {...}
      for _, v in pairs(a) do
	 f:write("# " .. v .. "\n")
      end
      f:close()
   end
   new_file("NEB.results", "NEB results file",
	    "Image reaction-coordinate Energy E-diff Curvature F-max(atom)")   
   for img = 1, self.n_images do
      new_file( ("NEB.%d.R"):format(img), "Coordinates")
      new_file( ("NEB.%d.F"):format(img), "Constrained force")
      new_file( ("NEB.%d.F.P"):format(img), "Perpendicular force")
      new_file( ("NEB.%d.F.S"):format(img), "Spring force")
      new_file( ("NEB.%d.F.NEB"):format(img), "Resulting NEB force")
      new_file( ("NEB.%d.T"):format(img), "NEB tangent")
      new_file( ("NEB.%d.dR_prev"):format(img), "Reaction distance (previous)")
      new_file( ("NEB.%d.dR_next"):format(img), "Reaction distance (next)")
   end
end
--- Print to screen some information regarding the NEB algorithm
function NEB:info()
  if self.neb_type=="NEB" then
   print ("============================================") 
   print ("  The NEB type is : Nudged Elastic Band     ")
   print ("============================================") 
  elseif self.neb_type == "DNEB" then
   print ("============================================") 
   print ("  The NEB type is : D-Nudged Elastic Band   ")
   print ("============================================") 
  end
   print("NEB has " .. self.n_images)
   print("NEB uses climbing after " .. self._climbing .. " steps")
   local tmp = array.Array( self.n_images + 1 )
   tmp[1] = self:dR(0, 1):norm(0)
   for i = 2, self.n_images + 1 do
      tmp[i] = tmp[i-1] + self:dR(i-1, i):norm(0)
   end
   print("NEB reaction coordinates: ")
   print(tostring(tmp))
   local tmp = array.Array( self.n_images )
   for i = 1, self.n_images do
      tmp[i] = self.k[i]
   end
   print("NEB spring constant: ")
   print(tostring(tmp))
end
-- Calculatin Perpendicular Spring force
function NEB:perpendicular_spring_force(image)
  self:_check_image(image)
  if self:tangent(image):norm(0)==0.0 then
     return  self:spring_force(image)
  else
  local PS=self:spring_force(image):project(self:tangent(image))
     return self:spring_force(image)-PS
  end
end
function NEB:file_exists(name)--name
   --local name
   --DM_name=tostring(name)
   DM_name=name
   --print ("DM_name is :" .. DM_name)
   local check
   --local DM_name = name
   local f = io.open(DM_name, "r") --name
   if f ~= nil then
      io.close(f)
      --check=true
      --print("TRUE: The file ".. DM_name..  " Exist!")
      return true
   else
      --print("False: The file ".. DM_name..  " Doesn't Exist!")
      return false
     --check=false      
   end
   --return check
end

return NEB