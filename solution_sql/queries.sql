-- Joseph Chang

-- Query 1
create view shippedVSCustDemand as
select cd.customer as customer, cd.item as item, IFNULL(sum(so.qty), 0) as suppliedQty, cd.qty as demandQty
from customerDemand cd LEFT OUTER JOIN shipOrders so
	ON cd.item = so.item and cd.customer = so.recipient
group by cd.customer, cd.item
order by cd.customer, cd.item;


-- Query 2
create view totalManufItems as 
select mo.item as item, sum(mo.qty) as totalManufQty
from manufOrders mo
group by mo.item
order by mo.item;


-- Query 3 Helper views
create view requiredMatItemQty as
select mo.manuf as manuf, mo.item as item, bom.matItem as matItem,
  (bom.QtyMatPerItem * IFNULL(sum(mo.qty), 0)) as requiredQty
from manufOrders mo JOIN billOfMaterials bom on mo.item = bom.prodItem
group by mo.manuf, mo.item, bom.matItem;
-- manufOrders(item, manuf, qty)
-- billOfMaterials(prodItem, matItem, QtyMatPerItem)

create view shippedMatItemQty as
select so.item as item, so.recipient as recipient,
  IFNULL(sum(so.qty), 0) as shippedQty
from shipOrders so
group by so.item, so.recipient;

-- Query 3
create view matsUsedVsShipped as
select rmiq.manuf as manuf, rmiq.matItem as matItem,
  IFNULL(sum(rmiq.requiredQty), 0) as requiredQty,
  IFNULL(smiq.shippedQty, 0) as shippedQty
from (
  requiredMatItemQty rmiq LEFT JOIN shippedMatItemQty smiq
  on rmiq.matItem = smiq.item and rmiq.manuf = smiq.recipient
)
group by rmiq.manuf, rmiq.matItem
order by rmiq.manuf, rmiq.matItem;


-- Query 4
create view producedVsShipped as
select mo.item as item, mo.manuf as manuf, IFNULL(sum(so.qty), 0) as ShippedOutQty, sum(mo.qty) as orderedQty
from manufOrders mo LEFT OUTER JOIN shipOrders so on mo.item = so.item and mo.manuf = so.sender
group by mo.item, mo.manuf
order by mo.item, mo.manuf;


-- Query 5
create view suppliedVsShipped as
select so.item as item, so.supplier as supplier,
	so.qty as suppliedQty, IFNULL(sum(ship.qty), 0) as ShippedQty
from supplyOrders so LEFT OUTER JOIN shipOrders ship
  on so.item = ship.item and so.supplier = ship.sender
group by so.item, so.supplier;


-- Query 6 Helper View
create view syoQTY as
select so.supplier as supplier, so.item as item, sum(so.qty)*sup.ppu as base
from supplyOrders so JOIN supplyUnitPricing sup on so.item = sup.item and so.supplier = sup.supplier
group by so.supplier, so.item;
-- Query 6
create view perSupplierCost as
select sd.supplier as supplier,
  IFNULL(
    LEAST(sd.amt1, sum(syo.base)) -- whichever is lower, sd amt1 or the base price
+ GREATEST(LEAST(sd.amt2, sum(syo.base)) - sd.amt1, 0) * (1 - sd.disc1)
+ GREATEST(sum(syo.base) - sd.amt2, 0) * (1 - sd.disc2)
  , 0) as cost
from syoQTY syo RIGHT OUTER JOIN supplierDiscounts sd on syo.supplier = sd.supplier
-- JOINED = (supplier, item, qty, ppu, amt1, disc1, amt2, disc2)
group by sd.supplier
order by sd.supplier;
-- supplyOrders(item, supplier, qty)
-- supplyUnitPricing(supplier, item, ppu)
-- supplierDiscounts(supplier, amt1, disc1, amt2, disc2)


-- Query 7 Helper View
create view mfQTY as
select mo.manuf as manuf, mo.item as item,
  (mup.setUpCost + (sum(mo.qty) * mup.prodCostPerUnit)) as base
from manufOrders mo JOIN manufUnitPricing mup on mo.manuf = mup.manuf and mo.item = mup.prodItem
group by mo.manuf, mo.item;
-- Query 7
create view perManufCost as
select md.manuf as manuf, 
  IFNULL(
  LEAST(md.amt1, sum(mo.base)) + GREATEST(sum(mo.base) - md.amt1, 0) * (1 - md.disc1)
  , 0) as cost
from mfQTY mo RIGHT OUTER JOIN manufDiscounts md on mo.manuf = md.manuf
group by md.manuf
order by md.manuf;
-- manufDiscounts(manuf, amt1, disc1)
-- manufUnitPricing(manuf, prodItem, setUpCost, prodCostPerUnit)
-- manufOrders(item, manuf, qty)







-- Query 8 Helper View
-- generate the weight per shipper's item in shipOrders
create view soQTY as
-- create view perShipperCost as
select so.shipper as shipper, so.item as item,
  so.sender as sender, so.recipient as recipient,
  sum(so.qty) as qty
--   shipOrders(item, shipper, sender, recipient, qty) items(item, unitWeight)
from shipOrders so
group by so.shipper, so.item, so.sender, so.recipient;

create view itWeight as
select so.shipper as shipper, so.item as item,
  so.sender as sender, so.recipient as recipient,
  so.qty*it.unitWeight as unitWeight
from soQTY so LEFT JOIN items it on so.item = it.item;

-- get the total weight for the shipper with respect to sender + recipient
create view shipWeight as
select  so.shipper as shipper,
        so.sender as sender, so.recipient as recipient, sum(so.unitWeight) as unitWeight
from itWeight so
group by so.shipper, so.sender, so.recipient;
-- soQTY(shipper, item, sender, recipient, unitWeight)

-- change the sender/recipient to the locations
create view soLOC as
select so.shipper as shipper, so.unitWeight as unitWeight,
        be1.shipLoc as fromLoc, be2.shipLoc as toLoc
from (shipWeight so LEFT JOIN busEntities be1 on so.sender = be1.entity)
      LEFT JOIN busEntities be2 on so.recipient = be2.entity;
-- shipOrders(item, shipper, sender, recipient, qty)
-- busEntities(entity, shipLoc, address, phone, web, contact)
-- soLOC(shipper, item, unitWeight, fromLoc, toLoc)

-- calculate base cost

create view soBase as
select so.shipper as shipper, so.fromLoc as fromLoc, so.toLoc as toLoc,
  so.unitWeight * sp.pricePerLb as base
from soLOC so JOIN shippingPricing sp
  on  so.shipper = sp.shipper and
      so.fromLoc = sp.fromLoc and so.toLoc = sp.toLoc;
-- soBase(shipper, fromLoc, toLoc, base)

create view soCosts as
select sp.shipper as shipper, sp.fromLoc as fromLoc, sp.toLoc as toLoc,
  GREATEST(
  IFNULL(
        -- base cost is calculated by (total/sum weight * pricePerLb)
        LEAST(sp.amt1, so.base)
      + GREATEST(LEAST(sp.amt2, so.base) - sp.amt1, 0) * (1 - sp.disc1)
      + GREATEST(so.base - sp.amt2, 0) * (1 - sp.disc2)
  , 0)
  , sp.minPackagePrice)
  as cost
from soBase so RIGHT OUTER JOIN shippingPricing sp
  on  so.shipper = sp.shipper and
      so.fromLoc = sp.fromLoc and so.toLoc = sp.toLoc
group by sp.shipper, sp.fromLoc, sp.toLoc;

-- TODO: answers are very close to correct answers but I cannot find it
-- Query 8
create view perShipperCost as
select so.shipper as shipper, sum(so.cost) as cost
from soCosts so
group by so.shipper
order by so.shipper;






-- TODO:
-- Query 9
-- Compute the total supply cost, manufacturing cost, and shipping cost. The resulting schema should be (supplyCost, manufCost, shippingCost, totalCost).
create view totalCostBreakDown as
select * from shipWeight;
-- select sum(sup.cost) as supplyCost, sum(man.cost) as manufCost, sum(ship.cost) as shippingCost, (sum(sup.cost) + sum(man.cost) + sum(ship.cost)) as totalCost
-- from perSupplierCost sup, perManufCost man, perShipperCost ship;


-- Query 10
create view customersWithUnsatisfiedDemand as
select distinct cd.customer as customer
from shippedVSCustDemand cd
where suppliedQty < demandQty
order by cd.customer;


-- Query 11
create view suppliersWithUnsentOrders as
select distinct sup.supplier as supplier
from suppliedVsShipped sup
where sup.suppliedQty > sup.ShippedQty
order by sup.supplier;

-- Query 12
create view manufsWoutEnoughMats as
select distinct mo.manuf as manuf
from matsUsedVsShipped mo
where requiredQty > shippedQty
order by mo.manuf;

-- Query 13
create view manufsWithUnsentOrders as
select mo.manuf as manuf
from producedVsShipped mo
where mo.orderedQty > mo.ShippedOutQty
group by mo.manuf
order by mo.manuf;
