@echo off
setlocal enabledelayedexpansion

:: Generazione timestamp per avere un nome univoco (es. 16-03-2026_15-55-32)
set "TIMESTAMP=%date:/=-%_%time::=-%"
set "TIMESTAMP=%TIMESTAMP: =0%"
set "TIMESTAMP=%TIMESTAMP:,=-%"

:: La cartella di destinazione dentro "lib"
set "DEST=Remidi\backup_%TIMESTAMP%"

echo.
echo ===================================================
echo Creazione punto di storage in "%DEST%"...
echo ===================================================
echo.

:: Esegue la copia di tutto il contenuto della cartella corrente (.)
:: /E copia le sottocartelle, anche vuote
:: /XD Remidi -> CRITICO: esclude la cartella dei backup per evitare un loop infinito
:: /XF *.bat -> esclude lo script stesso dalla copia
robocopy . "%DEST%" /E /XD Remidi /XF *.bat

:: Robocopy usa codici di uscita diversi. Valori inferiori a 8 indicano successo.
if %ERRORLEVEL% LSS 8 (
    echo.
    echo ===================================================
    echo Backup completato con successo.
    echo ===================================================
) else (
    echo.
    echo ===================================================
    echo ERRORE: Si sono verificati problemi durante il backup.
    echo ===================================================
)
echo.
pause