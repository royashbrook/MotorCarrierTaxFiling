-- synthetic placeholder: the fixtures never run this. it references the period variables so the
-- period-aware check has something to find.
select 1 as ord_hdrnumber where '$(PeriodStart)' <= '$(PeriodEnd)' and '$(Period)' <> '';
