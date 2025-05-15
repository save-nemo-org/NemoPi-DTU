local mobile = {}

function mobile.apn()
    
end

function mobile.imei()
   return "000000" 
end

function mobile.setAuto()

end

function mobile.reqCellInfo()
   sys.publish("CELL_INFO_UPDATE")
end

function mobile.getCellInfo()
   return {}
end

return mobile