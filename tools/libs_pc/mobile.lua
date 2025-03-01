local mobile = {}

function mobile.apn()
    
end

function mobile.imei()
   return "123456789012345" 
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