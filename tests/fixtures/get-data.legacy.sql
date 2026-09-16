-- synthetic placeholder shaped like a feed that still anchors its window on the run date.
select 1 as ord_hdrnumber where dateadd(month, -1, getdate()) < getdate();
